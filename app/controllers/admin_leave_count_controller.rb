# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'securerandom'

class AdminLeaveCountController < ApplicationController
  layout 'admin'
  menu_item :leave_count_configuration
  self.main_menu = false

  before_action :require_admin

  def index
    @leave_sync_settings = TaTeamSetting.leave_sync_settings
    @leave_sync_configured = TaTeamSetting.leave_sync_configured?
    @manual_pull_available = TaTeamSetting.leave_sync_manual_pull?
    @webhook_url = leave_google_apps_script_webhook_url
    @apps_script_template = build_apps_script_template
  end

  def create
    sync_params = leave_sync_params
    TaTeamSetting.update_leave_sync_settings!(
      enabled: sync_params[:leave_sync_enabled],
      recipient_email: sync_params[:leave_sync_recipient_email],
      historical_sync_start_date: sync_params[:leave_sync_start_date],
      leave_approach: sync_params[:leave_sync_approach],
      oauth_client_id: sync_params[:leave_oauth_client_id],
      oauth_client_secret: sync_params[:leave_oauth_client_secret],
      oauth_account_email: sync_params[:leave_oauth_account_email],
      dwd_delegated_user: sync_params[:leave_dwd_delegated_user],
      dwd_service_account_json: sync_params[:leave_dwd_service_account_json],
      gas_webhook_secret: sync_params[:leave_gas_webhook_secret]
    )
    flash[:notice] = l(:notice_leave_count_settings_updated)
  rescue ArgumentError => e
    flash[:error] = e.message
  ensure
    redirect_to admin_leave_count_path
  end

  def sync_leave_inbox
    settings = TaTeamSetting.leave_sync_settings
    if settings[:leave_approach] == 'google_apps_script'
      flash[:error] = l(:error_leave_push_based_no_manual_sync)
      return redirect_to admin_leave_count_path
    end

    sync_mode = params[:sync_mode].to_s == 'historical' ? :historical : :incremental
    result = RedmineTimeAnalytics::LeaveSyncService.new(settings: settings).sync!(mode: sync_mode)

    if result.errors.any?
      unique_errors = result.errors.uniq
      Rails.logger.warn(
        "[LeaveSync] completed with #{result.errors.length} errors (#{unique_errors.length} unique): #{unique_errors.first(10).join(' | ')}"
      )
      flash[:error] = "Leave sync finished with errors (#{result.errors.length} total). See log for details."
    else
      flash[:notice] = "Leave sync completed (Processed messages: #{result.processed_count}, Imported messages: #{result.imported_count}, Flagged messages: #{result.flagged_count})"
    end
  rescue StandardError => e
    flash[:error] = "Leave sync failed: #{e.message}"
  ensure
    redirect_to admin_leave_count_path
  end

  def oauth_start
    settings = TaTeamSetting.leave_sync_settings
    client_id = settings[:oauth_client_id].to_s.strip
    client_secret = settings[:oauth_client_secret].to_s
    account_email = settings[:oauth_account_email].to_s.strip
    if client_id.blank? || client_secret.blank? || account_email.blank?
      flash[:error] = l(:error_leave_oauth_missing_settings)
      return redirect_to admin_leave_count_path
    end

    state = SecureRandom.hex(24)
    redirect_uri = "#{request.base_url}#{admin_leave_count_oauth_callback_path}"
    session[:leave_oauth_state] = state
    session[:leave_oauth_redirect_uri] = redirect_uri

    oauth_params = {
      client_id: client_id,
      redirect_uri: redirect_uri,
      response_type: 'code',
      scope: 'https://www.googleapis.com/auth/gmail.readonly',
      access_type: 'offline',
      prompt: 'consent',
      include_granted_scopes: 'true',
      login_hint: account_email,
      state: state
    }
    redirect_to "https://accounts.google.com/o/oauth2/v2/auth?#{oauth_params.to_query}"
  end

  def oauth_callback
    expected_state = session.delete(:leave_oauth_state).to_s
    redirect_uri = session.delete(:leave_oauth_redirect_uri).to_s
    incoming_state = params[:state].to_s
    code = params[:code].to_s
    if expected_state.blank? || incoming_state.blank? || incoming_state != expected_state
      raise ArgumentError, l(:error_leave_oauth_state_mismatch)
    end
    raise ArgumentError, l(:error_leave_oauth_missing_code) if code.blank?

    settings = TaTeamSetting.leave_sync_settings
    token_data = exchange_oauth_code_for_tokens!(
      code: code,
      client_id: settings[:oauth_client_id],
      client_secret: settings[:oauth_client_secret],
      redirect_uri: redirect_uri
    )
    refresh_token = token_data['refresh_token'].to_s
    if refresh_token.blank? && settings[:oauth_refresh_token].blank?
      raise ArgumentError, l(:error_leave_oauth_refresh_token_missing)
    end

    TaTeamSetting.update_leave_oauth_refresh_token!(
      refresh_token: refresh_token.presence || settings[:oauth_refresh_token],
      account_email: settings[:oauth_account_email]
    )
    flash[:notice] = l(:notice_leave_oauth_connected)
  rescue ArgumentError => e
    flash[:error] = e.message
  rescue StandardError => e
    flash[:error] = "OAuth callback failed: #{e.message}"
  ensure
    redirect_to admin_leave_count_path
  end

  private

  def leave_sync_params
    params.permit(
      :leave_sync_enabled,
      :leave_sync_recipient_email,
      :leave_sync_start_date,
      :leave_sync_approach,
      :leave_oauth_client_id,
      :leave_oauth_client_secret,
      :leave_oauth_account_email,
      :leave_dwd_delegated_user,
      :leave_dwd_service_account_json,
      :leave_gas_webhook_secret
    )
  end

  def exchange_oauth_code_for_tokens!(code:, client_id:, client_secret:, redirect_uri:)
    uri = URI.parse('https://oauth2.googleapis.com/token')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request.set_form_data(
      code: code,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      grant_type: 'authorization_code'
    )

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end
    payload = JSON.parse(response.body)
    unless response.code.to_i.between?(200, 299)
      raise ArgumentError, payload['error_description'].presence || payload['error'].presence || 'Token exchange failed'
    end

    payload
  rescue JSON::ParserError
    raise ArgumentError, 'Token exchange returned an invalid response'
  end

  def build_apps_script_template
    <<~SCRIPT
      // Google Apps Script template for leave webhook push
      // 1) Update WEBHOOK_URL and WEBHOOK_SECRET
      // 2) Set a time-driven trigger to run pushLeaveEmails()
      const WEBHOOK_URL = "#{leave_google_apps_script_webhook_url}";
      const WEBHOOK_SECRET = "<your-webhook-secret>";
      const RECIPIENT_EMAIL = "vacation-group@entgra.io";

      function pushLeaveEmails() {
        const threads = GmailApp.search('to:' + RECIPIENT_EMAIL + ' newer_than:1d');
        const messages = [];
        threads.forEach((thread) => {
          thread.getMessages().forEach((mail) => {
            messages.push({
              message_id: String(mail.getId()),
              thread_id: String(thread.getId()),
              from: mail.getFrom(),
              to: mail.getTo(),
              subject: mail.getSubject(),
              sent_at: mail.getDate().toISOString(),
              body: mail.getPlainBody()
            });
          });
        });

        const body = JSON.stringify({ messages: messages });
        const signature = Utilities.computeHmacSha256Signature(body, WEBHOOK_SECRET)
          .map((b) => ('0' + (b < 0 ? b + 256 : b).toString(16)).slice(-2))
          .join('');

        UrlFetchApp.fetch(WEBHOOK_URL, {
          method: 'post',
          contentType: 'application/json',
          payload: body,
          headers: {
            'X-Webhook-Signature': signature
          },
          muteHttpExceptions: true
        });
      }
    SCRIPT
  end
end
