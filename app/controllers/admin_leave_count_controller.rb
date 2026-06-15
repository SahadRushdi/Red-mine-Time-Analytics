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
    @leave_ai_api_key_present = @leave_sync_settings[:ai_api_key].present?
    @leave_sync_configured = TaTeamSetting.leave_sync_configured?
    @manual_pull_available = TaTeamSetting.leave_sync_manual_pull?
    @leave_sync_enabled = @leave_sync_settings[:enabled]
    @leave_sync_cron = @leave_sync_settings[:cron]
    @leave_sync_scheduler_active = @leave_sync_enabled && @leave_sync_configured
    if @leave_sync_scheduler_active
      @leave_sync_next_run_at = RedmineTimeAnalytics::LeaveSyncScheduler.next_run_at(settings: @leave_sync_settings)
    end
  end

  def create
    sync_params = leave_sync_params
    settings = TaTeamSetting.leave_sync_settings
    
    # AI should be enabled if it was explicitly enabled in the form OR 
    # if a new API key is provided OR if an existing API key exists and we are not disabling it.
    ai_enabled = sync_params[:leave_ai_extraction_enabled] == '1' || 
                 sync_params[:leave_ai_api_key].present? ||
                 (settings[:ai_api_key].present? && sync_params[:leave_ai_extraction_enabled] != '0')

    cron_expression = TaTeamSetting.generate_cron_from_ui(sync_params)

    TaTeamSetting.update_leave_sync_settings!(
      enabled: sync_params[:leave_sync_enabled],
      recipient_email: sync_params[:leave_sync_recipient_email],
      historical_sync_start_date: sync_params[:leave_sync_start_date],
      historical_sync_end_date: sync_params[:leave_sync_end_date],
      leave_approach: 'oauth',
      oauth_client_id: sync_params[:leave_oauth_client_id],
      oauth_client_secret: sync_params[:leave_oauth_client_secret],
      oauth_account_email: sync_params[:leave_oauth_account_email],
      leave_sync_cron: cron_expression,
      leave_sync_freq_type: sync_params[:leave_sync_freq_type],
      leave_sync_interval_value: sync_params[:leave_sync_interval_value],
      leave_sync_interval_unit: sync_params[:leave_sync_interval_unit],
      leave_sync_daily_time: sync_params[:leave_sync_daily_time],
      leave_sync_everyday_time: sync_params[:leave_sync_everyday_time],
      leave_sync_daily_days: sync_params[:leave_sync_daily_days],
      ai_extraction_enabled: ai_enabled,
      ai_provider: 'google',
      ai_model: sync_params[:leave_ai_model],
      ai_api_key: sync_params[:leave_ai_api_key]
    )
    RedmineTimeAnalytics::LeaveSyncScheduler.refresh!
    flash[:notice] = l(:notice_leave_count_settings_updated)
  rescue ArgumentError => e
    flash[:error] = e.message
  ensure
    redirect_to admin_leave_count_path
  end

  def sync_leave_inbox
    sync_mode = params[:sync_mode].to_s == 'historical' ? :historical : :incremental
    sync_id = SecureRandom.hex(8)
    
    # Start sync in background using Sucker Punch
    RedmineTimeAnalytics::LeaveSyncJob.perform_async(sync_mode, sync_id)

    message = if sync_mode == :historical
                "Historical sync started."
              else
                "Incremental sync started. This should complete shortly."
              end

    render json: { sync_id: sync_id, message: message }
  end

  def sync_status
    sync_id = params[:sync_id]
    progress = RedmineTimeAnalytics::SyncTracker.get(sync_id) || { status: 'starting', message: 'Initializing...', progress: 0 }
    render json: progress
  end

  def ai_models
    api_key = TaTeamSetting.leave_sync_settings[:ai_api_key].to_s
    if api_key.blank?
      return render json: { error: 'no_api_key' }, status: :unprocessable_entity
    end

    render json: { models: fetch_google_models(api_key) }
  rescue StandardError => e
    Rails.logger.warn("[LeaveAI] model list fetch failed: #{e.class}: #{e.message}")
    render json: { error: 'fetch_failed' }, status: :bad_gateway
  end

  def next_run
    cron = TaTeamSetting.generate_cron_from_ui(next_run_params)
    cron_line = RedmineTimeAnalytics::LeaveSyncScheduler.cron_line_for(cron)
    next_time = cron_line&.next_time(Time.zone.now)
    formatted = next_time ? helpers.format_time(next_time.to_t) : nil
    render json: { next_run: formatted }
  rescue StandardError
    render json: { next_run: nil }
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
      :leave_sync_end_date,
      :leave_oauth_client_id,
      :leave_oauth_client_secret,
      :leave_oauth_account_email,
      :leave_sync_cron,
      :leave_sync_freq_type,
      :leave_sync_interval_value,
      :leave_sync_interval_unit,
      :leave_sync_daily_time,
      :leave_sync_everyday_time,
      :leave_ai_extraction_enabled,
      :leave_ai_model,
      :leave_ai_api_key,
      leave_sync_daily_days: []
    )
  end

  def fetch_google_models(api_key)
    uri = URI.parse("https://generativelanguage.googleapis.com/v1beta/models?key=#{URI.encode_www_form_component(api_key)}&pageSize=200")
    request = Net::HTTP::Get.new(uri)

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 8) do |http|
      http.request(request)
    end
    payload = JSON.parse(response.body.to_s)
    unless response.code.to_i.between?(200, 299)
      error_message = payload['error'].is_a?(Hash) ? payload['error']['message'] : payload['error']
      raise(error_message.presence || "Model list request failed with HTTP #{response.code}")
    end

    Array(payload['models']).filter_map do |model|
      methods = Array(model['supportedGenerationMethods'])
      next unless methods.include?('generateContent')

      model['name'].to_s.sub(%r{\Amodels/}, '').presence
    end.uniq.sort
  end

  def next_run_params
    params.permit(
      :leave_sync_freq_type,
      :leave_sync_interval_value,
      :leave_sync_interval_unit,
      :leave_sync_daily_time,
      :leave_sync_everyday_time,
      leave_sync_daily_days: []
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
end
