# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require_relative 'leave_email_parser'

module RedmineTimeAnalytics
  class AiLeaveExtractor
    AI_HTTP_RETRYABLE_CODES = [429, 500, 502, 503, 504].freeze
    AI_HTTP_MAX_RETRIES = 2
    AI_HTTP_RETRY_DELAY_SECONDS = 2
    DATE_OVERRIDE_KEYWORDS = ['shift', 'shifted', 'reschedul', 'moved to', 'updated', 'update',
                              'changed to', 'correction', 'correct', 'next week', 'next day',
                              'tomorrow', 'today', 'yesterday', 'this afternoon', 'this morning',
                              'tonight', 'later', 'replacement', 'revised'].freeze

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a strict data extractor for leave requests. Output JSON ONLY.
      
      STEP 1: LATEST MESSAGE RESOLUTION (Truth Supremacy)
      - Your output MUST reflect the FINAL state of the request based on the newest visible reply.
      - Ignore quoted history (text after ">" or "[Quoted text hidden]"). 
      - If the latest message "shifts", "moves", "reschedules", or "changes" a leave: 
        1. Identify the OLD date being abandoned.
        2. Identify the NEW date being requested.
        3. Only return the NEW date(s) as "confirmed". Do NOT return the old dates in any capacity.
      
      STEP 2: HANDLING SHIFTS & CORRECTIONS (Case 8, 9, & 10 Fix)
      - CRITICAL: If a message says "shifted to next week (05.02.2026)", the date in the Subject line (e.g., 29.01.2026) is now INVALID. 
      - You must exclude the original subject dates if they have been moved or corrected in the reply.
      - Example (Case 8/9):
        Subject: "Half day leave - 29.01.2026"
        Latest Body: "This leave is shifted to 05.02.2026 and it will be a full day."
        RESULT: Output ONLY 2026-02-05 with fraction 1.0. (Exclude 2026-01-29 entirely).

      STEP 3: DATE-FRACTION MAPPING (Case 5 Fix)
      - Do NOT apply one fraction to all dates in a list.
      - Look for modifiers (Half Day, Morning, Evening, Full Day) specifically linked to each date.
      - Use 0.5 for: "Half day", "Morning", "Evening", "Late arrival", "After 12:30".
      - Use 1.0 for: "Full day", "On leave", "Sick", or when a reply "upgrades" a leave to full day.

      STEP 4: OUTPUT JSON
      {
        "status": "confirmed" | "cancelled" | "flagged",
        "reason": "latest_message_priority_shift_applied",
        "leave_entries": [
          {"date": "YYYY-MM-DD", "fraction": 1.0 | 0.5}
        ]
      }

      RULES:
      - Ignore punctuation (. / -) and casing in subject lines.
      - Use "Sent at" year if missing from the text.
      - "cancelled" status is only used if the user is revoking a leave without a replacement. If there is a replacement, use "confirmed" with the NEW date only.
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

      parsed = begin
        ai_payload = request_ai!(
          subject: message[:subject].to_s,
          body: message[:body].to_s,
          primary_body: primary_body_text(message[:body].to_s),
          sent_at: normalize_sent_time(message[:sent_at]) || Time.zone.now
        )
        parsed_result(ai_payload, user: user)
      rescue StandardError => e
        Rails.logger.warn("[LeaveAI] provider error: #{e.class}: #{e.message}") if defined?(Rails)
        result(status: :flagged, reason: 'ai_model_failed', user: user, date_source: :ai)
      end
      post_process_result(parsed: parsed, message: message, recipient_email: recipient_email, user: user)
    end

    def parse_batch(messages:, recipient_email:, chunk_size: 50)
      indexed = Array(messages).map.with_index { |message, index| { message: message, index: index } }
      results = Array.new(indexed.length)
      ai_candidates = []

      indexed.each do |item|
        message = item[:message]
        sender_email = normalize_email(message[:from])
        recipient = normalize_email(recipient_email)
        to_addresses = extract_recipient_addresses(message[:to])

        unless to_addresses.include?(recipient)
          results[item[:index]] = result(status: :ignored, reason: 'recipient_not_matched')
          next
        end

        user = find_active_user_by_email(sender_email)
        unless user
          results[item[:index]] = result(status: :flagged, reason: 'user_not_found', date_source: :ai)
          next
        end

        ai_candidates << item.merge(user: user)
      end

      ai_candidates.each_slice(chunk_size) do |slice|
        inputs = slice.map do |item|
          message = item[:message]
          {
            message_id: batch_message_id(message, item[:index]),
            subject: message[:subject].to_s,
            body: message[:body].to_s,
            primary_body: primary_body_text(message[:body].to_s),
            sent_at: (normalize_sent_time(message[:sent_at]) || Time.zone.now).iso8601
          }
        end

        batch_map = begin
          request_ai_batch!(messages: inputs)
        rescue StandardError => e
          Rails.logger.warn("[LeaveAI] batch provider error: #{e.class}: #{e.message}") if defined?(Rails)
          {}
        end

        slice.each do |item|
          payload = batch_map[batch_message_id(item[:message], item[:index])]
          if payload.nil?
            results[item[:index]] = retry_individual_parse(item[:message], recipient_email, item[:user])
            next
          end

          parsed = parsed_result(payload, user: item[:user])
          results[item[:index]] = post_process_result(
            parsed: parsed,
            message: item[:message],
            recipient_email: recipient_email,
            user: item[:user]
          )
        end
      end

      results.map.with_index do |parsed, index|
        parsed || result(status: :flagged, reason: 'ai_batch_missing_response', date_source: :ai)
      end
    end

    private

    def post_process_result(parsed:, message:, recipient_email:, user:)
      explicit_entries = explicit_leave_entries_from_message(
        subject: message[:subject].to_s,
        body: message[:body].to_s,
        sent_at: message[:sent_at]
      )

      if cancellation_request?(message[:subject].to_s, message[:body].to_s)
        cancellation_dates = explicit_entries.any? ? explicit_entries : parsed.leave_entries
        return result(
          status: :cancelled,
          reason: 'cancelled',
          user: user,
          leave_dates: cancellation_dates.map { |entry| entry[:date] }.uniq.sort,
          leave_fraction: cancellation_dates.map { |entry| entry[:fraction].to_f }.max || 0.0,
          leave_entries: cancellation_dates,
          date_source: :ai
        )
      end

      if explicit_entries.length > 1 && parsed.leave_dates.length < explicit_entries.length
        fallback = result(
          status: :confirmed,
          reason: 'ai_analyzed',
          user: user,
          leave_dates: explicit_entries.map { |entry| entry[:date] }.uniq.sort,
          leave_fraction: explicit_entries.map { |entry| entry[:fraction].to_f }.max || 1.0,
          leave_entries: explicit_entries,
          date_source: :ai
        )
        return fallback
      end

      sanitized = remove_sent_date_leak(parsed: parsed, message: message, explicit_entries: explicit_entries)
      return sanitized if sanitized != parsed

      return parsed unless parsed.status == :flagged && parsed.leave_entries.blank?

      fallback = fallback_from_message(
        subject: message[:subject].to_s,
        body: message[:body].to_s,
        user: user,
        sent_at: message[:sent_at],
        recipient_email: recipient_email
      )
      fallback.leave_entries.any? ? fallback : parsed
    end

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

    def request_ai_batch!(messages:)
      provider = settings[:ai_provider].to_s
      model = settings[:ai_model].to_s
      api_key = settings[:ai_api_key].to_s
      base_url = settings[:ai_base_url].to_s
      raise 'AI provider is required' if provider.blank?
      raise 'AI model is required' if model.blank?
      raise 'AI API key is required' if api_key.blank?

      user_prompt = <<~TEXT
        Extract leave details for each email below.
        Return JSON only in this schema:
        {
          "results": [
            {
              "message_id": "exact_input_message_id",
              "status": "confirmed|cancelled|flagged",
              "reason": "short_reason",
              "leave_entries": [{"date":"YYYY-MM-DD","fraction":1.0|0.5}]
            }
          ]
        }
        Include one result for every input message_id.

        Emails JSON:
        #{JSON.generate(messages)}
      TEXT

      raw = case provider
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
      normalize_batch_payload(raw)
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

      attempts = 0
      loop do
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
          http.request(request)
        end
        payload = JSON.parse(response.body.to_s)
        if retryable_http_response?(response, payload) && attempts < AI_HTTP_MAX_RETRIES
          attempts += 1
          sleep(ai_retry_delay(attempts))
          next
        end

        unless response.code.to_i.between?(200, 299)
          error_message = payload['error'].is_a?(Hash) ? payload['error']['message'] : payload['error']
          raise(error_message.presence || "AI request failed with HTTP #{response.code}")
        end

        return payload
      end
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

    def normalize_batch_payload(raw_payload)
      items = case raw_payload
              when Hash
                result_nodes = raw_payload['results'] || raw_payload[:results]
                result_nodes.is_a?(Array) ? result_nodes : [raw_payload]
              when Array
                raw_payload
              else
                []
              end

      items.each_with_object({}) do |node, acc|
        item = node.respond_to?(:to_h) ? node.to_h : {}
        message_id = item['message_id'].to_s.strip
        next if message_id.blank?

        acc[message_id] = {
          'status' => item['status'].to_s,
          'reason' => item['reason'].to_s,
          'leave_entries' => item['leave_entries'].is_a?(Array) ? item['leave_entries'] : []
        }
      end
    end

    def primary_body_text(text)
      normalized = text.to_s.gsub("\r\n", "\n")
      lines = normalized.lines
      separator_index = lines.index do |line|
        line.match?(/\A\s*>\s?/) ||
          line.match?(/\Aon .+wrote:\s*\z/i) ||
          line.match?(/\A-----original message-----\s*\z/i) ||
          line.match?(/\A\[quoted text hidden\]\s*\z/i)
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

    def fallback_from_message(subject:, body:, user:, sent_at:, recipient_email:)
      legacy_result = legacy_parse(
        subject: subject,
        body: body,
        user: user,
        sent_at: sent_at,
        recipient_email: recipient_email
      )
      return legacy_result if legacy_result && legacy_result.status != :flagged

      reference_time = normalize_sent_time(sent_at) || Time.zone.now
      entries = explicit_leave_entries_from_message(subject: subject, body: body, sent_at: reference_time)

      if entries.any?
        result(
          status: :confirmed,
          reason: 'ai_analyzed',
          user: user,
          leave_dates: entries.map { |entry| entry[:date] }.uniq.sort,
          leave_fraction: entries.map { |entry| entry[:fraction].to_f }.max || 1.0,
          leave_entries: entries,
          date_source: :ai
        )
      else
        result(status: :flagged, reason: 'ai_model_failed', user: user, date_source: :ai)
      end
    end

    def legacy_parse(subject:, body:, user:, sent_at:, recipient_email:)
      parser = RedmineTimeAnalytics::LeaveEmailParser.new
      parser.parse(
        message: {
          from: user_email_for_lookup(user),
          to: recipient_email,
          subject: subject,
          body: body,
          sent_at: normalize_sent_time(sent_at) || Time.zone.now
        },
        recipient_email: recipient_email
      )
    rescue StandardError => e
      Rails.logger.warn("[LeaveAI] legacy fallback failed: #{e.class}: #{e.message}") if defined?(Rails)
      nil
    end

    def explicit_leave_entries_from_message(subject:, body:, sent_at:)
      reference_time = normalize_sent_time(sent_at) || Time.zone.now
      subject_entries = parse_explicit_entries(subject, reference_time)
      body_entries = parse_explicit_entries(primary_body_text(body), reference_time)
      if body_override_subject?(body, subject_entries, body_entries)
        subject_dates = subject_entries.map { |entry| entry[:date] }
        filtered_body_entries = body_entries.reject { |entry| subject_dates.include?(entry[:date]) }
        return filtered_body_entries.any? ? filtered_body_entries : body_entries
      end

      (subject_entries + body_entries).uniq { |entry| entry[:date] }
    end

    def remove_sent_date_leak(parsed:, message:, explicit_entries:)
      sent_date = normalize_sent_time(message[:sent_at])&.to_date
      return parsed if sent_date.nil? || parsed.leave_entries.length < 2

      parsed_dates = parsed.leave_entries.map { |entry| entry[:date] }
      return parsed unless parsed_dates.include?(sent_date)

      explicit_dates = explicit_entries.map { |entry| entry[:date] }.uniq
      return parsed unless explicit_dates.any? && (explicit_dates - [sent_date]).any?

      filtered_entries = parsed.leave_entries.reject { |entry| entry[:date] == sent_date }
      return parsed if filtered_entries.empty?

      result(
        status: parsed.status,
        reason: parsed.reason,
        user: parsed.user,
        leave_dates: filtered_entries.map { |entry| entry[:date] }.uniq.sort,
        leave_fraction: filtered_entries.map { |entry| entry[:fraction].to_f }.max || parsed.leave_fraction,
        leave_entries: filtered_entries,
        date_source: parsed.date_source
      )
    end

    def parse_explicit_entries(text, reference_time)
      normalized = normalize_date_text(text.to_s)
      entries = explicit_segments(normalized).flat_map do |segment|
        dates = extract_dates_from_text(segment)
        dates.concat(expand_comma_day_lists(segment, reference_time))
        dates.concat(expand_ampersand_day_lists(segment, reference_time))
        dates = expand_range_dates(segment, dates)
        fraction = fraction_for_text(segment)

        dates.compact.uniq.sort.map do |date|
          { date: date, fraction: fraction }
        end
      end

      if entries.empty?
        return extract_dates_from_text(normalized).map do |date|
          { date: date, fraction: fraction_for_text(normalized) }
        end
      end

      entries.uniq { |entry| entry[:date] }.sort_by { |entry| entry[:date] }
    end

    def expand_range_dates(text, dates)
      return dates if dates.length < 2
      return dates unless explicit_range_text?(text)

      first_date = dates.min
      last_date = dates.max
      return dates if first_date.nil? || last_date.nil? || last_date < first_date

      (first_date..last_date).to_a
    end

    def explicit_range_text?(text)
      text.match?(/\b(?:from|between|through|until)\b/i)
    end

    def user_email_for_lookup(user)
      if user.respond_to?(:mail) && !user.mail.to_s.empty?
        user.mail
      else
        user.respond_to?(:email) ? user.email : nil
      end
    end

    def explicit_segments(text)
      protected = protect_day_list_ampersands(text.to_s)
      protected.split(/(?:\n|[.!?;]|\s+\band\b\s+|\s+\&\s+)/i)
               .map { |segment| segment.gsub('__AMP__', '&') }
               .map(&:strip)
               .reject(&:empty?)
    end

    def body_override_subject?(body_text, subject_entries, body_entries)
      return false unless body_entries.any? && subject_entries.any?

      normalized_body = normalize_date_text(primary_body_text(body_text)).downcase
      DATE_OVERRIDE_KEYWORDS.any? { |keyword| normalized_body.include?(keyword) }
    end

    def protect_day_list_ampersands(text)
      month_regex = '(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|' \
                    'jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|' \
                    'nov(?:ember)?|dec(?:ember)?)'
      text.gsub(/(\b\d{1,2})\s*&\s*(\d{1,2}(?:\s*,\s*\d{1,2})*\s*(?:of\s+)?#{month_regex}(?:\s+\d{4})?\b)/i, '\1 __AMP__ \2')
    end

    def fraction_for_text(text)
      normalized = normalize_date_text(text.to_s).downcase
      return 0.5 if normalized.match?(/\b(half\s*day|half-day|morning|evening|first half|second half|late arrival|late-arrival|after 12:30|early leave)\b/i)
      return 1.0 if normalized.match?(/\b(full\s*day|full-day|whole day|entire day|on leave|leave)\b/i)

      1.0
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

    def normalize_date_text(text)
      text.to_s
          .gsub(/\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/, '\1/\2/\3')
          .gsub(/\b(\d{1,2})(st|nd|rd|th)\b/i, '\1')
    end

    def expand_comma_day_lists(text, reference_time)
      normalized = text.to_s
      month_regex = '(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|' \
                    'jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|' \
                    'nov(?:ember)?|dec(?:ember)?)'
      dates = []

      normalized.scan(/\b(\d{1,2}(?:\s*,\s*\d{1,2})+)\s*(?:of\s+)?(#{month_regex})(?:\s+(\d{4}))?\b/i).each do |day_list, month_name, year|
        year = year.present? ? year.to_i : reference_time.year
        day_list.split(/\s*,\s*/).each do |day_str|
          begin
            dates << Date.parse("#{month_name} #{day_str}, #{year}")
          rescue ArgumentError
            next
          end
        end
      end

      dates.compact.uniq.sort
    end

    def expand_ampersand_day_lists(text, reference_time)
      normalized = text.to_s
      month_regex = '(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|' \
                    'jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|' \
                    'nov(?:ember)?|dec(?:ember)?)'
      dates = []

      normalized.scan(/\b(\d{1,2}(?:\s*&\s*\d{1,2})+)\s*(?:of\s+)?(#{month_regex})(?:\s+(\d{4}))?\b/i).each do |day_list, month_name, year|
        year = year.present? ? year.to_i : reference_time.year
        day_list.split(/\s*&\s*/).each do |day_str|
          begin
            dates << Date.parse("#{month_name} #{day_str}, #{year}")
          rescue ArgumentError
            next
          end
        end
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

    def retryable_http_response?(response, payload)
      code = response.code.to_i
      return true if AI_HTTP_RETRYABLE_CODES.include?(code)

      error = payload['error']
      error_text = error.is_a?(Hash) ? error.values.join(' ') : error.to_s
      error_text.match?(/rate limit|too many requests|resource exhausted|overloaded/i)
    end

    def ai_retry_delay(attempt)
      AI_HTTP_RETRY_DELAY_SECONDS * attempt
    end

    def retry_individual_parse(message, recipient_email, user)
      parse(message: message, recipient_email: recipient_email)
    rescue StandardError => e
      Rails.logger.warn("[LeaveAI] missing batch item retry failed: #{e.class}: #{e.message}") if defined?(Rails)
      result(status: :flagged, reason: 'ai_batch_missing_response', user: user, date_source: :ai)
    end

    def batch_message_id(message, index)
      message_id = message[:message_id].to_s.strip
      return message_id if message_id.present?

      "batch-email-#{index}"
    end

    def cancellation_request?(subject, body)
      normalized = [subject, primary_body_text(body)].compact.join("\n").downcase
      normalized.match?(/\b(cancelled|canceled|cancel|cancelling|cancellation|ignore|working instead|able to work|work instead)\b/)
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
