# frozen_string_literal: true

require 'base64'
require 'json'
require 'stringio'

module RedmineTimeAnalytics
  class GmailLeaveFetcher
    def initialize(settings)
      @settings = settings
      load_gmail_dependencies!
    end

    def fetch_messages(mode:, recipient_email:, historical_start_date:, synced_after:)
      query = ["to:#{recipient_email}"]
      if mode.to_s == 'historical'
        query << "after:#{historical_start_date.strftime('%Y/%m/%d')}" if historical_start_date
      elsif synced_after
        query << "after:#{synced_after.strftime('%Y/%m/%d')}"
      end

      response = gmail_service.list_user_messages('me', q: query.join(' '), max_results: 250)
      Array(response.messages).map { |message_ref| build_message_payload(message_ref.id) }.compact
    end

    private

    def load_gmail_dependencies!
      require 'google/apis/gmail_v1'
      require 'googleauth'
    rescue LoadError => e
      raise "Gmail API dependencies are missing: #{e.message}"
    end

    def gmail_service
      return @gmail_service if defined?(@gmail_service) && @gmail_service

      service = Google::Apis::GmailV1::GmailService.new
      service.authorization = authorization
      @gmail_service = service
    end

    def authorization
      credentials_json = @settings[:gmail_service_account_json].to_s
      delegated_user = @settings[:gmail_delegated_user].to_s.strip
      if credentials_json.blank? || delegated_user.blank?
        raise 'Gmail delegated user and service account JSON are required'
      end

      scopes = [Google::Apis::GmailV1::AUTH_GMAIL_READONLY]
      creds = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(credentials_json),
        scope: scopes
      )
      creds.sub = delegated_user
      creds.fetch_access_token!
      creds
    end

    def build_message_payload(message_id)
      msg = gmail_service.get_user_message('me', message_id, format: 'full')
      payload = msg.payload
      headers = extract_headers(payload)
      {
        message_id: msg.id,
        thread_id: msg.thread_id,
        from: headers['from'],
        to: headers['to'],
        subject: headers['subject'],
        sent_at: parse_date(headers['date']) || Time.zone.now,
        body: extract_body(payload)
      }
    rescue StandardError
      nil
    end

    def extract_headers(payload)
      Array(payload&.headers).each_with_object({}) do |header, acc|
        acc[header.name.to_s.downcase] = header.value
      end
    end

    def extract_body(part)
      return '' if part.nil?

      data = part.body&.data
      if data.present? && (part.mime_type == 'text/plain' || part.parts.blank?)
        return Base64.urlsafe_decode64(data.tr('-_', '+/'))
      end

      Array(part.parts).each do |sub_part|
        body = extract_body(sub_part)
        return body if body.present?
      end
      ''
    rescue ArgumentError
      ''
    end

    def parse_date(value)
      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end
  end
end
