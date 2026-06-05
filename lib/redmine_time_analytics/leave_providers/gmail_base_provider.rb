# frozen_string_literal: true

require 'base64'
require 'cgi'
require 'json'
require 'stringio'

module RedmineTimeAnalytics
  module LeaveProviders
    class GmailBaseProvider < BaseProvider
      def initialize(settings)
        super(settings)
        load_gmail_dependencies!
      end

      def fetch_messages(mode:, recipient_email:, historical_start_date:, historical_end_date:, synced_after:, tracker: nil)
        tracker&.update(message: 'Fetching Emails...', progress: 10)
        query = ["to:#{recipient_email}"]
        if mode.to_s == 'historical'
          query << "after:#{historical_start_date.strftime('%Y/%m/%d')}" if historical_start_date
          query << "before:#{(historical_end_date + 1).strftime('%Y/%m/%d')}" if historical_end_date
        elsif synced_after
          query << "after:#{synced_after.strftime('%Y/%m/%d')}"
        end

        message_refs = []
        page_token = nil
        loop do
          response = gmail_service.list_user_messages('me', q: query.join(' '), max_results: 250, page_token: page_token)
          message_refs.concat(Array(response.messages))
          page_token = response.next_page_token
          break if page_token.blank?
        end

        cutoff = mode.to_s == 'historical' ? [historical_start_date, historical_end_date].compact : synced_after
        total_refs = message_refs.length
        payloads = []
        message_refs.each_with_index do |message_ref, index|
          if index % 20 == 0
            tracker&.update(message: "Downloading emails (#{index + 1} of #{total_refs})...", progress: 10 + (index.to_f / total_refs * 10).to_i)
          end
          payloads << build_message_payload(message_ref.id)
        end
        payloads.compact.select { |message| within_requested_window?(message[:sent_at], mode, cutoff) }
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
        raise NotImplementedError, 'Subclasses must provide authorization'
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
          body: extract_body(payload).presence || msg.snippet.to_s
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
        if data.present? && part.mime_type == 'text/plain'
          return Base64.urlsafe_decode64(data.tr('-_', '+/'))
        end

        if data.present? && part.mime_type == 'text/html'
          return html_to_text(Base64.urlsafe_decode64(data.tr('-_', '+/')))
        end

        Array(part.parts).each do |sub_part|
          body = extract_body(sub_part)
          return body if body.present?
        end

        if data.present?
          decoded = Base64.urlsafe_decode64(data.tr('-_', '+/'))
          return decoded if decoded.present?
        end
        ''
      rescue ArgumentError
        ''
      end

      def html_to_text(html)
        CGI.unescapeHTML(html.to_s.gsub(/<\/(p|div|tr|li|h[1-6])>/i, "\n").gsub(/<br\s*\/?>/i, "\n").gsub(/<[^>]+>/, ' ')).gsub(/[ \t]+/, ' ').gsub(/\n\s+/, "\n").strip
      end

      def parse_date(value)
        Time.zone.parse(value.to_s)
      rescue StandardError
        nil
      end

      def within_requested_window?(sent_at, mode, cutoff)
        return true if sent_at.nil? || cutoff.nil?

        if mode.to_s == 'historical'
          start_date, end_date = Array(cutoff)
          within_start = start_date.nil? || sent_at.to_date >= start_date.to_date
          within_end = end_date.nil? || sent_at.to_date <= end_date.to_date
          within_start && within_end
        else
          sent_at > cutoff
        end
      end
    end
  end
end
