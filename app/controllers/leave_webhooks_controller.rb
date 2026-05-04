# frozen_string_literal: true

require 'openssl'
require 'json'

class LeaveWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:google_apps_script]

  def google_apps_script
    settings = TaTeamSetting.leave_sync_settings
    if settings[:leave_approach] != 'google_apps_script'
      return render json: { error: 'Google Apps Script approach is not enabled' }, status: :unprocessable_entity
    end

    raw_body = request.raw_post.to_s
    unless valid_signature?(raw_body, settings[:gas_webhook_secret].to_s)
      return render json: { error: 'Invalid webhook signature' }, status: :unauthorized
    end

    payload = JSON.parse(raw_body)
    messages = normalize_messages(payload)
    result = RedmineTimeAnalytics::LeaveSyncService.new(settings: settings).sync_messages!(
      messages: messages,
      mode: :google_apps_script_push
    )

    if result.errors.any?
      render json: { ok: false, errors: result.errors.uniq, processed: result.processed_count }, status: :unprocessable_entity
    else
      render json: { ok: true, processed: result.processed_count, imported: result.imported_count, flagged: result.flagged_count }, status: :ok
    end
  rescue JSON::ParserError
    render json: { error: 'Invalid JSON payload' }, status: :unprocessable_entity
  rescue StandardError => e
    render json: { error: e.message }, status: :internal_server_error
  end

  private

  def valid_signature?(raw_body, secret)
    return true if secret.blank?

    received = request.headers['X-Webhook-Signature'].to_s.strip
    return false if received.blank?

    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, raw_body)
    return false if received.bytesize != expected.bytesize

    ActiveSupport::SecurityUtils.secure_compare(received, expected)
  end

  def normalize_messages(payload)
    entries = payload.is_a?(Hash) ? payload['messages'] : payload
    Array(entries).map do |entry|
      item = entry.respond_to?(:to_h) ? entry.to_h : {}
      {
        message_id: item['message_id'].to_s.presence || item['id'].to_s,
        thread_id: item['thread_id'].to_s,
        from: item['from'].to_s,
        to: item['to'].to_s,
        subject: item['subject'].to_s,
        sent_at: parse_time(item['sent_at']) || Time.zone.now,
        body: item['body'].to_s
      }
    end
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end
end
