# frozen_string_literal: true

module RedmineTimeAnalytics
  class SimpleLeaveEmailParser
    HALF_DAY_KEYWORDS = ['half day', 'half-day', 'morning', 'evening', 'first half', 'second half',
                         'late arrival', 'late-arrival', 'after noon', 'after lunch', 'arriving after'].freeze
    FULL_DAY_KEYWORDS = ['full day', 'full-day', 'whole day', 'entire day'].freeze
    LEAVE_KEYWORDS = ['leave', 'on leave', 'sick leave', 'vacation', 'holiday', 'absent'].freeze

    def parse(message:, recipient_email:)
      sender_email = normalize_email(message[:from])
      recipient = normalize_email(recipient_email)
      to_addresses = extract_recipient_addresses(message[:to])

      unless to_addresses.include?(recipient)
        return result(status: :ignored, reason: 'recipient_not_matched')
      end

      user = find_active_user_by_email(sender_email)
      return result(status: :flagged, reason: 'user_not_found', user: nil) unless user

      subject_text = message[:subject].to_s
      normalized_subject = subject_text.downcase
      unless LEAVE_KEYWORDS.any? { |keyword| normalized_subject.include?(keyword) }
        return result(status: :flagged, reason: 'no_leave_context', user: user)
      end

      sent_at = sent_time(message[:sent_at]) || Time.zone.now
      subject_dates = extract_explicit_dates(subject_text, sent_at)
      if subject_dates.empty?
        return result(status: :flagged, reason: 'no_date_found', user: user)
      end

      working_dates = subject_dates.select { |date| RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(date) }
      if working_dates.empty?
        return result(status: :flagged, reason: 'no_working_day_found', user: user, leave_dates: subject_dates)
      end

      fraction = determine_leave_fraction(normalized_subject)
      result(
        status: :confirmed,
        user: user,
        leave_dates: working_dates,
        leave_fraction: fraction,
        leave_entries: working_dates.map { |date| { date: date, fraction: fraction } },
        date_source: :subject
      )
    rescue StandardError
      result(status: :flagged, reason: 'parse_error')
    end

    private

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
        body_has_explicit_date: false,
        used_sent_fallback: false
      )
    end

    def determine_leave_fraction(normalized_subject)
      return 1.0 if FULL_DAY_KEYWORDS.any? { |keyword| normalized_subject.include?(keyword) }
      return 0.5 if HALF_DAY_KEYWORDS.any? { |keyword| normalized_subject.include?(keyword) }

      1.0
    end

    def extract_explicit_dates(text, reference_time)
      normalized = normalize_date_text(text)
      dates = []

      normalized.scan(/\b\d{4}-\d{2}-\d{2}\b/).each do |candidate|
        dates << Date.strptime(candidate, '%Y-%m-%d')
      rescue ArgumentError
        next
      end

      normalized.scan(/\b\d{4}[\/.]\d{1,2}[\/.]\d{1,2}\b/).each do |candidate|
        dates << parse_year_first_date(candidate)
      end

      normalized.scan(/\b\d{1,2}\/\d{1,2}\/\d{4}\b/).each do |candidate|
        dates << parse_slash_date(candidate, reference_time)
      end

      dates.concat(expand_numeric_day_lists(normalized, reference_time))

      month_regex = '(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|' \
                    'jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|' \
                    'nov(?:ember)?|dec(?:ember)?)'
      normalized.scan(/\b#{month_regex}\s+\d{1,2}(?:,\s*\d{4})?\b/i).each do |candidate|
        dates << Date.parse(apply_reference_year(candidate, reference_time))
      rescue ArgumentError
        next
      end

      normalized.scan(/\b\d{1,2}\s+#{month_regex}(?:\s+\d{4})?\b/i).each do |candidate|
        dates << Date.parse(apply_reference_year(candidate, reference_time))
      rescue ArgumentError
        next
      end

      dates.compact.uniq.sort
    end

    # Handles day-lists sharing a numeric month/year, e.g. "08,09/07/2026" or "08,09/07"
    # (year falls back to reference_time). Distinct from a single DD/MM/YYYY date because
    # the day-list requires at least one comma-separated sibling before the month.
    def expand_numeric_day_lists(text, reference_time)
      dates = []
      text.scan(%r{\b(\d{1,2}(?:\s*,\s*\d{1,2})+)\s*/\s*(\d{1,2})(?:\s*/\s*(\d{4}))?\b}) do |day_list, month_str, year_str|
        month = month_str.to_i
        year = year_str.present? ? year_str.to_i : reference_time.to_date.year
        day_list.split(/\s*,\s*/).each do |day_str|
          dates << Date.new(year, month, day_str.to_i)
        rescue ArgumentError
          next
        end
      end
      dates
    end

    def apply_reference_year(candidate, reference_time)
      return candidate if candidate.match?(/\b\d{4}\b/)

      "#{candidate} #{reference_time.to_date.year}"
    end

    def parse_slash_date(candidate, reference_time = nil)
      parts = candidate.split('/').map(&:to_i)
      return nil if parts.length != 3

      first, second, year = parts
      ambiguous = first <= 12 && second <= 12
      format = if first > 12 || second <= 12
                 '%d/%m/%Y'
               else
                 '%m/%d/%Y'
               end
      date = Date.strptime(candidate, format)
      return date unless ambiguous && reference_time

      reference_date = reference_time.to_date
      return date if date == reference_date

      alternate = begin
        Date.new(year, first, second)
      rescue ArgumentError
        nil
      end
      alternate && alternate == reference_date ? alternate : date
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

    def normalize_date_text(text)
      text.to_s
          .gsub(/\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/, '\1/\2/\3')
    end

    def sent_time(value)
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

      User.active.sorted.find { |user| normalize_lookup_email(user_email(user)) == normalized_sender } ||
        User.where(status: User::STATUS_LOCKED).sorted.find { |user| normalize_lookup_email(user_email(user)) == normalized_sender }
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
