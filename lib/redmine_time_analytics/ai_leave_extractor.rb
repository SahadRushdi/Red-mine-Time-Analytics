# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module RedmineTimeAnalytics
  class AiLeaveExtractor
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You extract leave details from a leave-request email.
      Output JSON only (no markdown).
      JSON schema:
      {
        "status": "confirmed" | "cancelled" | "flagged",
        "reason": "short_reason_string",
        "leave_entries": [
          {"date": "YYYY-MM-DD", "fraction": 1.0 or 0.5}
        ]
      }
      Rules:
      - Use only 1.0 for full-day and 0.5 for half-day.
      - If the request is cancellation, set status to "cancelled" and return dates to cancel in leave_entries.
      - Analyze the latest reply body first; if the email is a reply thread, the newest body overrides quoted older text.
      - Prefer the most recently updated date in the message when there are corrections or shifted dates.
      - Do not flag just because the wording is informal or because there is a mix of subject/body text.
      - If you can determine any leave date and leave type, return "confirmed".
      - Return "flagged" only for non-leave emails or when no leave date can be determined at all.
    PROMPT

    def initialize(settings:)
      @settings = settings
    end

    def parse(message:, recipient_email:)
      sender_email = normalize_email(message[:from])
      recipient = normalize_email(recipient_email)
      to_addresses = extract_recipient_addresses(message[:to])

      unless to_addresses.include?(recipient)
        return result(status: :ignored, reason: 'recipient_not_matched')
      end

      user = find_active_user_by_email(sender_email)
      return result(status: :flagged, reason: 'user_not_found') unless user

      ai_payload = request_ai!(
        subject: message[:subject].to_s,
        body: message[:body].to_s,
        primary_body: primary_body_text(message[:body].to_s),
        sent_at: normalize_sent_time(message[:sent_at]) || Time.zone.now
      )
      parsed_result(ai_payload, user: user)
    end

    private

    attr_reader :settings

    def parsed_result(payload, user:)
      status = payload['status'].to_s.strip.downcase
      reason = payload['reason'].to_s.strip.presence
      leave_entries = normalize_leave_entries(payload['leave_entries'])
      leave_dates = leave_entries.map { |entry| entry[:date] }.uniq.sort
      leave_fraction = leave_entries.map { |entry| entry[:fraction].to_f }.max || 0.0

      case status
      when 'cancelled'
        result(
          status: :cancelled,
          reason: reason || 'cancelled',
          user: user,
          leave_dates: leave_dates,
          leave_fraction: leave_fraction,
          leave_entries: leave_entries,
          date_source: :ai
        )
      when 'flagged'
        if leave_entries.any?
          result(
            status: :confirmed,
            reason: 'ai_analyzed',
            user: user,
            leave_dates: leave_dates,
            leave_fraction: leave_fraction,
            leave_entries: leave_entries,
            date_source: :ai
          )
        else
          result(
            status: :flagged,
            reason: reason || 'ai_flagged',
            user: user,
            leave_dates: leave_dates,
            leave_fraction: leave_fraction,
            leave_entries: leave_entries,
            date_source: :ai
          )
        end
      when 'confirmed'
        working_entries = leave_entries.select do |entry|
          RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(entry[:date])
        end
        if working_entries.empty?
          return result(
            status: :flagged,
            reason: 'no_working_day_found',
            user: user,
            leave_dates: leave_dates,
            leave_fraction: leave_fraction,
            leave_entries: [],
            date_source: :ai
          )
        end

        working_dates = working_entries.map { |entry| entry[:date] }.uniq.sort
        result(
          status: :confirmed,
          user: user,
          leave_dates: working_dates,
          leave_fraction: working_entries.map { |entry| entry[:fraction].to_f }.max || 1.0,
          leave_entries: working_entries,
          date_source: :ai
        )
      else
        if leave_entries.any?
          result(
            status: :confirmed,
            reason: 'ai_analyzed',
            user: user,
            leave_dates: leave_dates,
            leave_fraction: leave_fraction,
            leave_entries: leave_entries,
            date_source: :ai
          )
        else
          result(status: :flagged, reason: reason || 'invalid_ai_status', user: user)
        end
      end
    end

    def normalize_leave_entries(entries)
      Array(entries).filter_map do |entry|
        item = entry.respond_to?(:to_h) ? entry.to_h : {}
        date = parse_date(item['date'] || item[:date])
        next if date.nil?

        fraction = normalize_fraction(item['fraction'] || item[:fraction])
        { date: date, fraction: fraction }
      end
    end

    def normalize_fraction(value)
      number = value.to_f
      return 1.0 if number >= 0.75

      0.5
    end

    def parse_date(value)
      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def request_ai!(subject:, body:, primary_body:, sent_at:)
      provider = settings[:ai_provider].to_s
      model = settings[:ai_model].to_s
      api_key = settings[:ai_api_key].to_s
      base_url = settings[:ai_base_url].to_s
      raise 'AI provider is required' if provider.blank?
      raise 'AI model is required' if model.blank?
      raise 'AI API key is required' if api_key.blank?

      user_prompt = <<~TEXT
        Email subject:
        #{subject}

        Latest reply body:
        #{primary_body}

        Full email body:
        #{body}

        Sent at:
        #{sent_at.iso8601}
      TEXT

      case provider
      when 'google'
        call_google(model: model, api_key: api_key, base_url: base_url, user_prompt: user_prompt)
      when 'openai'
        call_openai(model: model, api_key: api_key, base_url: base_url, user_prompt: user_prompt)
      when 'anthropic'
        call_anthropic(model: model, api_key: api_key, base_url: base_url, user_prompt: user_prompt)
      when 'custom'
        call_openai(model: model, api_key: api_key, base_url: base_url, user_prompt: user_prompt)
      else
        raise "Unsupported AI provider: #{provider}"
      end
    end

    def call_google(model:, api_key:, base_url:, user_prompt:)
      endpoint =
        if base_url.present?
          base_url
        else
          encoded_model = URI.encode_www_form_component(model)
          encoded_key = URI.encode_www_form_component(api_key)
          "https://generativelanguage.googleapis.com/v1beta/models/#{encoded_model}:generateContent?key=#{encoded_key}"
        end

      payload = http_post_json(
        endpoint,
        headers: { 'Content-Type' => 'application/json' },
        body: {
          systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
          contents: [{ role: 'user', parts: [{ text: user_prompt }] }],
          generationConfig: {
            temperature: 0.0,
            responseMimeType: 'application/json'
          }
        }
      )
      text = payload.dig('candidates', 0, 'content', 'parts', 0, 'text').to_s
      parse_model_json(text)
    end

    def call_openai(model:, api_key:, base_url:, user_prompt:)
      endpoint = base_url.presence || 'https://api.openai.com/v1/chat/completions'
      payload = http_post_json(
        endpoint,
        headers: {
          'Content-Type' => 'application/json',
          'Authorization' => "Bearer #{api_key}"
        },
        body: {
          model: model,
          temperature: 0.0,
          messages: [
            { role: 'system', content: SYSTEM_PROMPT },
            { role: 'user', content: user_prompt }
          ]
        }
      )
      text = payload.dig('choices', 0, 'message', 'content').to_s
      parse_model_json(text)
    end

    def call_anthropic(model:, api_key:, base_url:, user_prompt:)
      endpoint = base_url.presence || 'https://api.anthropic.com/v1/messages'
      payload = http_post_json(
        endpoint,
        headers: {
          'Content-Type' => 'application/json',
          'x-api-key' => api_key,
          'anthropic-version' => '2023-06-01'
        },
        body: {
          model: model,
          max_tokens: 400,
          temperature: 0.0,
          system: SYSTEM_PROMPT,
          messages: [
            { role: 'user', content: user_prompt }
          ]
        }
      )
      content = payload['content']
      text = if content.is_a?(Array)
               content.find { |item| item.is_a?(Hash) && item['type'] == 'text' }.to_h['text'].to_s
             else
               ''
             end
      parse_model_json(text)
    end

    def http_post_json(endpoint, headers:, body:)
      uri = URI.parse(endpoint)
      request = Net::HTTP::Post.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = JSON.generate(body)

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end
      payload = JSON.parse(response.body.to_s)
      unless response.code.to_i.between?(200, 299)
        error_message = payload['error'].is_a?(Hash) ? payload['error']['message'] : payload['error']
        raise(error_message.presence || "AI request failed with HTTP #{response.code}")
      end

      payload
    rescue JSON::ParserError
      raise 'AI provider returned invalid JSON'
    end

    def parse_model_json(text)
      json_text = text.to_s.strip
      if json_text.start_with?('```')
        json_text = json_text.gsub(/\A```(?:json)?\s*/i, '').gsub(/\s*```\z/, '').strip
      end
      candidates = [json_text]
      extracted = json_text[/\{.*\}/m]
      candidates << extracted if extracted.present?

      candidates.each do |candidate|
        next if candidate.blank?

        begin
          parsed = JSON.parse(candidate)
          return parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          next
        end
      end

      fallback_parse_from_text(text)
    end

    def primary_body_text(text)
      normalized = text.to_s.gsub("\r\n", "\n")
      lines = normalized.lines
      separator_index = lines.index do |line|
        line.match?(/\A\s*>\s?/) ||
          line.match?(/\Aon .+wrote:\s*\z/i) ||
          line.match?(/\A-----original message-----\s*\z/i)
      end
      separator_index ? lines.take(separator_index).join : normalized
    end

    def fallback_parse_from_text(text)
      normalized = text.to_s.downcase
      dates = extract_dates_from_text(text)
      status = if normalized.include?('cancel')
                 'cancelled'
               elsif normalized.include?('flag')
                 'flagged'
               elsif dates.any?
                 'confirmed'
               else
                 'flagged'
               end
      fraction = if normalized.include?('half')
                   0.5
                 else
                   1.0
                 end
      {
        'status' => status,
        'reason' => (status == 'flagged' ? 'ai_model_failed' : 'ai_analyzed'),
        'leave_entries' => dates.map { |date| { 'date' => date.to_s, 'fraction' => fraction } }
      }
    end

    def extract_dates_from_text(text)
      normalized = text.to_s
      dates = []

      normalized.scan(/\b\d{4}-\d{2}-\d{2}\b/).each do |candidate|
        dates << Date.strptime(candidate, '%Y-%m-%d')
      rescue ArgumentError
        next
      end

      normalized.scan(/\b\d{4}[\/.]\d{1,2}[\/.]\d{1,2}\b/).each do |candidate|
        date = parse_year_first_date(candidate)
        dates << date if date
      end

      normalized.scan(/\b\d{1,2}\/\d{1,2}\/\d{4}\b/).each do |candidate|
        date = parse_slash_date(candidate)
        dates << date if date
      end

      month_regex = '(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|' \
                    'jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|' \
                    'nov(?:ember)?|dec(?:ember)?)'
      normalized.scan(/\b#{month_regex}\s+\d{1,2}(?:,\s*\d{4})?\b/i).each do |candidate|
        dates << Date.parse(candidate)
      rescue ArgumentError
        next
      end

      normalized.scan(/\b\d{1,2}\s+#{month_regex}(?:\s+\d{4})?\b/i).each do |candidate|
        dates << Date.parse(candidate)
      rescue ArgumentError
        next
      end

      dates.compact.uniq.sort
    end

    def parse_slash_date(candidate)
      parts = candidate.split('/').map(&:to_i)
      return nil if parts.length != 3

      first, second, year = parts
      format = if first > 12 || second <= 12
                 '%d/%m/%Y'
               else
                 '%m/%d/%Y'
               end
      Date.strptime(candidate, format)
    rescue ArgumentError
      nil
    end

    def parse_year_first_date(candidate)
      parts = candidate.split(/[\/.]/).map(&:to_i)
      return nil if parts.length != 3

      Date.new(parts[0], parts[1], parts[2])
    rescue ArgumentError
      nil
    end

    def result(status:, reason: nil, user: nil, leave_dates: [], leave_fraction: 0.0, leave_entries: [], date_source: :none)
      RedmineTimeAnalytics::LeaveEmailParser::Result.new(
        status: status,
        reason: reason,
        user: user,
        leave_dates: leave_dates,
        leave_fraction: leave_fraction,
        leave_entries: leave_entries,
        date_source: date_source,
        subject_has_explicit_date: leave_dates.any?,
        body_has_explicit_date: leave_dates.any?,
        used_sent_fallback: false
      )
    end

    def normalize_sent_time(value)
      return value.in_time_zone if value.respond_to?(:in_time_zone)
      return value if value.is_a?(Time) || value.is_a?(DateTime)

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def normalize_email(value)
      value.to_s.downcase.scan(/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i).first.to_s.downcase
    end

    def extract_recipient_addresses(raw_to)
      raw_to.to_s.downcase.scan(/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i).map(&:downcase).uniq
    end

    def find_active_user_by_email(sender_email)
      normalized_sender = normalize_lookup_email(sender_email)
      return nil if normalized_sender.to_s.empty?

      User.active.sorted.find { |user| normalize_lookup_email(user_email(user)) == normalized_sender }
    end

    def normalize_lookup_email(value)
      email = value.to_s.strip.downcase
      return '' unless email.include?('@')

      local_part, domain = email.split('@', 2)
      return '' if local_part.to_s.empty? || domain.to_s.empty?

      normalized_local = local_part.split('+', 2).first
      normalized_domain = domain
      if %w[gmail.com googlemail.com].include?(normalized_domain)
        normalized_local = normalized_local.delete('.')
        normalized_domain = 'gmail.com'
      end

      "#{normalized_local}@#{normalized_domain}"
    end

    def user_email(user)
      if user.respond_to?(:mail) && !user.mail.to_s.empty?
        user.mail
      else
        user.respond_to?(:email) ? user.email : nil
      end
    end
  end
end
