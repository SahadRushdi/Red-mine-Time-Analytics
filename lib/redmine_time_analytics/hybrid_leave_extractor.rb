# frozen_string_literal: true

module RedmineTimeAnalytics
  class HybridLeaveExtractor
    COMPLEXITY_KEYWORDS = ['re:', 'reply', 'shift', 'shifted', 'reschedul', 'moved to', 'updated', 'changed to',
                           'cancel', 'cancelled', 'canceled', 'withdraw', 'revoked', 'revoke',
                           'from', 'between', 'through', 'until'].freeze
    LEAVE_CONTEXT_KEYWORDS = ['leave', 'on leave', 'sick leave', 'vacation', 'holiday', 'absent'].freeze
    MULTI_DATE_LIST_REGEX = /
      \b\d{1,2}(?:\s*,\s*\d{1,2})+\s*(?:of\s+)?(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|
      jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+\d{4})?\b|
      \b\d{1,2}\s*&\s*\d{1,2}\b|
      \b(?:from|between|through|until)\b
    /ix.freeze
    DATE_TOKEN_REGEX = /
      \b\d{4}-\d{2}-\d{2}\b|
      \b\d{4}[\/.]\d{1,2}[\/.]\d{1,2}\b|
      \b\d{1,2}[\/.]\d{1,2}[\/.]\d{4}\b|
      \b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|
      jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:,\s*\d{4})?\b|
      \b\d{1,2}\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|
      jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+\d{4})?\b
    /ix.freeze

    def initialize(settings:)
      @settings = settings
      @simple_parser = RedmineTimeAnalytics::SimpleLeaveEmailParser.new
      @ai_extractor = RedmineTimeAnalytics::AiLeaveExtractor.new(settings: settings)
    end

    def parse(message:, recipient_email:)
      if simple_subject_request?(message)
        return @simple_parser.parse(message: message, recipient_email: recipient_email)
      end

      unless ai_enabled_and_configured?
        return flagged(message: message, recipient_email: recipient_email, reason: 'ai_model_not_configured')
      end

      @ai_extractor.parse(message: message, recipient_email: recipient_email)
    rescue StandardError => e
      Rails.logger.warn("[LeaveAI] model extraction failed: #{e.class}: #{e.message}") if defined?(Rails)
      flagged(message: message, recipient_email: recipient_email, reason: 'ai_model_failed')
    end

    def parse_batch(messages:, recipient_email:, chunk_size: 50)
      indexed = Array(messages).map.with_index { |message, index| { message: message, index: index } }
      results = Array.new(indexed.length)
      ai_candidates = []

      indexed.each do |item|
        message = item[:message]
        if simple_subject_request?(message)
          results[item[:index]] = @simple_parser.parse(message: message, recipient_email: recipient_email)
          next
        end

        unless ai_enabled_and_configured?
          results[item[:index]] = flagged(message: message, recipient_email: recipient_email, reason: 'ai_model_not_configured')
          next
        end

        ai_candidates << item
      end

      ai_candidates.each_slice(chunk_size) do |slice|
        batch_results = @ai_extractor.parse_batch(
          messages: slice.map { |item| item[:message] },
          recipient_email: recipient_email,
          chunk_size: chunk_size
        )
        slice.each_with_index do |item, index|
          results[item[:index]] = batch_results[index] || flagged(
            message: item[:message],
            recipient_email: recipient_email,
            reason: 'ai_batch_missing_response'
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[LeaveAI] batch extraction failed: #{e.class}: #{e.message}") if defined?(Rails)
        slice.each do |item|
          results[item[:index]] = parse(message: item[:message], recipient_email: recipient_email)
        rescue StandardError => inner_error
          Rails.logger.warn("[LeaveAI] fallback parse failed: #{inner_error.class}: #{inner_error.message}") if defined?(Rails)
          results[item[:index]] = flagged(message: item[:message], recipient_email: recipient_email, reason: 'ai_model_failed')
        end
      end

      results
    end

    private

    def ai_enabled_and_configured?
      @settings[:ai_extraction_enabled] &&
        @settings[:ai_provider].to_s.present? &&
        @settings[:ai_model].to_s.present? &&
        @settings[:ai_api_key].to_s.present?
    end

    def simple_subject_request?(message)
      subject_text = message[:subject].to_s
      body_text = primary_body_text(message[:body].to_s)
      normalized_subject = subject_text.downcase
      normalized_body = body_text.downcase
      sent_year = normalize_sent_time(message[:sent_at])&.year

      return false unless LEAVE_CONTEXT_KEYWORDS.any? { |keyword| normalized_subject.include?(keyword) }
      return false if multi_date_subject?(normalized_subject)
      return false if COMPLEXITY_KEYWORDS.any? { |keyword| normalized_subject.include?(keyword) }
      return false if COMPLEXITY_KEYWORDS.any? { |keyword| normalized_body.include?(keyword) }
      return false if contains_date_token?(normalized_body)

      subject_dates = subject_text.scan(DATE_TOKEN_REGEX)
      return false unless subject_dates.length == 1

      if sent_year.present?
        subject_years = subject_text.scan(/\b(\d{4})\b/).flatten.map(&:to_i).uniq
        return false if subject_years.any? && !subject_years.include?(sent_year)
      end

      true
    end

    def contains_date_token?(text)
      text.match?(DATE_TOKEN_REGEX)
    end

    def multi_date_subject?(subject_text)
      subject_text.match?(MULTI_DATE_LIST_REGEX) || subject_text.scan(DATE_TOKEN_REGEX).length > 1
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

    def flagged(message:, recipient_email:, reason:)
      sender_email = normalize_email(message[:from])
      recipient = normalize_email(recipient_email)
      to_addresses = extract_recipient_addresses(message[:to])
      return result(status: :ignored, reason: 'recipient_not_matched') unless to_addresses.include?(recipient)

      user = find_active_user_by_email(sender_email)
      result(status: :flagged, reason: reason, user: user, date_source: :ai)
    end

    def result(status:, reason:, user: nil, date_source: :none)
      RedmineTimeAnalytics::LeaveEmailParser::Result.new(
        status: status,
        reason: reason,
        user: user,
        leave_dates: [],
        leave_fraction: 0.0,
        leave_entries: [],
        date_source: date_source,
        subject_has_explicit_date: false,
        body_has_explicit_date: false,
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
