# frozen_string_literal: true

require 'chronic'
require 'nickel'

module RedmineTimeAnalytics
  class LeaveEmailParser
    Result = Struct.new(:status, :reason, :user, :leave_dates, :leave_fraction, keyword_init: true)

    CANCELLATION_KEYWORDS = ['cancel', 'cancelled', 'canceled', 'withdraw', 'revoked', 'revoke'].freeze
    HALF_DAY_KEYWORDS = ['half day', 'half-day', 'morning', 'evening', 'first half', 'second half'].freeze
    FULL_DAY_KEYWORDS = ['full day', 'full-day', 'whole day', 'entire day'].freeze
    FULL_DAY_FRACTION = 1.0
    HALF_DAY_FRACTION = 0.5
    MONTH_REGEX = '(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|' \
                   'jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|' \
                   'nov(?:ember)?|dec(?:ember)?)'.freeze

    def parse(message:, recipient_email:)
      sender_email = normalize_email(message[:from])
      recipient = normalize_email(recipient_email)
      to_addresses = extract_recipient_addresses(message[:to])

      unless to_addresses.include?(recipient)
        return Result.new(status: :ignored, reason: 'recipient_not_matched', leave_dates: [], leave_fraction: 0)
      end

      user = find_active_user_by_email(sender_email)
      return Result.new(status: :flagged, reason: 'user_not_found', leave_dates: [], leave_fraction: 0) unless user

      subject_text = message[:subject].to_s
      body_text = message[:body].to_s
      normalized_sent_time = sent_time(message[:sent_at])
      reference_time = normalized_sent_time || Time.zone.now
      leave_fraction = determine_leave_fraction(subject_text: subject_text, body_text: body_text)

      if cancellation_request?(subject_text: subject_text, body_text: body_text)
        cancellation_dates = extract_dates_with_priority(
          subject_text: subject_text,
          body_text: body_text,
          reference_time: reference_time
        )
        return Result.new(
          status: :cancelled,
          reason: 'cancelled',
          user: user,
          leave_dates: cancellation_dates,
          leave_fraction: leave_fraction
        )
      end

      extracted_dates = extract_dates_with_priority(
        subject_text: subject_text,
        body_text: body_text,
        reference_time: reference_time
      )
      fallback_date = reference_time&.to_date
      extracted_dates = [fallback_date] if extracted_dates.empty? && fallback_date
      if extracted_dates.empty?
        return Result.new(status: :flagged, reason: 'no_date_found', user: user, leave_dates: [], leave_fraction: leave_fraction)
      end

      working_dates = extracted_dates.select { |date| RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(date) }.uniq.sort
      if working_dates.empty?
        return Result.new(
          status: :flagged,
          reason: 'no_working_day_found',
          user: user,
          leave_dates: extracted_dates.uniq.sort,
          leave_fraction: leave_fraction
        )
      end

      Result.new(status: :confirmed, user: user, leave_dates: working_dates, leave_fraction: leave_fraction)
    rescue StandardError
      Result.new(status: :flagged, reason: 'parse_error', leave_dates: [], leave_fraction: 0)
    end

    private

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

    def cancellation_request?(subject_text:, body_text:)
      normalized = [subject_text, body_text].compact.join("\n").downcase
      CANCELLATION_KEYWORDS.any? { |keyword| normalized.include?(keyword) }
    end

    def determine_leave_fraction(subject_text:, body_text:)
      normalized = [subject_text, primary_body_text(body_text)].compact.join("\n").downcase
      return HALF_DAY_FRACTION if HALF_DAY_KEYWORDS.any? { |keyword| normalized.include?(keyword) }
      return FULL_DAY_FRACTION if FULL_DAY_KEYWORDS.any? { |keyword| normalized.include?(keyword) }

      FULL_DAY_FRACTION
    end

    def extract_dates_with_priority(subject_text:, body_text:, reference_time:)
      subject_dates = extract_dates_from_text(subject_text, reference_time)
      return subject_dates if subject_dates.any?

      extract_dates_from_text(primary_body_text(body_text), reference_time)
    end

    def sent_time(value)
      return value.in_time_zone if value.respond_to?(:in_time_zone)
      return value if value.is_a?(Time) || value.is_a?(DateTime)

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
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

    def extract_dates_from_text(text, reference_time)
      normalized = text.to_s

      dates = []

      normalized.scan(/\b\d{4}-\d{2}-\d{2}\b/).each do |candidate|
        dates << Date.strptime(candidate, '%Y-%m-%d')
      rescue ArgumentError
        next
      end

      normalized.scan(/\b\d{1,2}\/\d{1,2}\/\d{4}\b/).each do |candidate|
        dates << parse_slash_date(candidate)
      end

      normalized.scan(/\b#{MONTH_REGEX}\s+\d{1,2}(?:,\s*\d{4})?\b/i).each do |candidate|
        dates << Date.parse(candidate)
      rescue ArgumentError
        next
      end

      normalized.scan(/\b\d{1,2}\s+#{MONTH_REGEX}(?:\s+\d{4})?\b/i).each do |candidate|
        dates << Date.parse(candidate)
      rescue ArgumentError
        next
      end

      dates = expand_ranges(normalized, dates.compact.uniq.sort)
      return dates if dates.any?

      chronic_dates = extract_dates_with_chronic(normalized, reference_time)
      return chronic_dates if chronic_dates.any?

      extract_dates_with_nickel(normalized, reference_time)
    end

    def extract_dates_with_nickel(text, reference_time)
      parsed = Nickel.parse(text, reference_time)
      Array(parsed&.occurrences).flat_map do |occurrence|
        start_date = parsed_date(occurrence.start_date)
        end_date = parsed_date(occurrence.end_date)

        if start_date && end_date && end_date > start_date
          (start_date..end_date).to_a
        elsif start_date
          [start_date]
        else
          []
        end
      end
    rescue StandardError
      []
    end

    def extract_dates_with_chronic(text, reference_time)
      parsed = Chronic.parse(text, now: reference_time, guess: false)
      return [] if parsed.nil?

      if parsed.is_a?(Chronic::Span)
        start_date = parsed_date(parsed.begin)
        end_date = parsed_date(parsed.end)
        return [] if start_date.nil?
        return [start_date] if parsed.respond_to?(:width) && parsed.width <= 86_400
        return [start_date] if end_date.nil? || end_date <= start_date

        (start_date..end_date).to_a
      else
        date = parsed_date(parsed)
        date ? [date] : []
      end
    rescue StandardError
      []
    end

    def parsed_date(value)
      return value.to_date if value.respond_to?(:to_date)
      return value if value.is_a?(Date)

      Date.parse(value.to_s)
    rescue StandardError
      nil
    end

    def parse_slash_date(candidate)
      parts = candidate.split('/').map(&:to_i)
      return nil if parts.length != 3

      first, second, year = parts
      # Prefer DD/MM/YYYY because the organization emails leave dates in that format.
      format = if first > 12 || second <= 12
                 '%d/%m/%Y'
               else
                 '%m/%d/%Y'
               end
      Date.strptime(candidate, format)
    rescue ArgumentError
      nil
    end

    def expand_ranges(text, dates)
      return dates if dates.length < 2

      expanded = dates.dup
      text.scan(/(#{date_token_regex})\s*(?:to|-)\s*(#{date_token_regex})/i).each do |start_token, end_token|
        start_date = safe_parse_date_token(start_token)
        end_date = safe_parse_date_token(end_token)
        next if start_date.nil? || end_date.nil? || end_date < start_date

        (start_date..end_date).each { |date| expanded << date }
      end

      expanded.uniq.sort
    end

    def date_token_regex
      '\d{4}-\d{2}-\d{2}|\d{1,2}\/\d{1,2}\/\d{4}|' \
        '(?:' + MONTH_REGEX + ')\s+\d{1,2}(?:,\s*\d{4})?|' \
        '\d{1,2}\s+(?:' + MONTH_REGEX + ')(?:\s+\d{4})?'
    end

    def safe_parse_date_token(token)
      return Date.strptime(token, '%Y-%m-%d') if token.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      return parse_slash_date(token) if token.match?(/\A\d{1,2}\/\d{1,2}\/\d{4}\z/)

      Date.parse(token)
    rescue ArgumentError
      nil
    end
  end
end
