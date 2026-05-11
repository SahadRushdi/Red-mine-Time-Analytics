# frozen_string_literal: true

require 'chronic'
require 'nickel'

module RedmineTimeAnalytics
  class LeaveEmailParser
    Result = Struct.new(
      :status,
      :reason,
      :user,
      :leave_dates,
      :leave_fraction,
      :leave_entries,
      :date_source,
      :subject_has_explicit_date,
      :body_has_explicit_date,
      :used_sent_fallback,
      keyword_init: true
    )

    CANCELLATION_KEYWORDS = ['cancel', 'cancelled', 'canceled', 'withdraw', 'revoked', 'revoke'].freeze
    HALF_DAY_KEYWORDS = ['half day', 'half-day', 'morning', 'evening', 'first half', 'second half',
                         'late arrival', 'late-arrival', 'after noon', 'after lunch', 'arriving after'].freeze
    FULL_DAY_KEYWORDS = ['full day', 'full-day', 'whole day', 'entire day'].freeze
    ATTENDANCE_KEYWORDS = ['attending office', 'coming to the office', 'coming to office', 'joining office',
                           'will be at the office', 'will be at office', 'arriving at the office',
                           'arriving to the office', 'going to office', 'coming to work'].freeze
    LEAVE_CONTEXT_KEYWORDS = ['leave', 'sick leave', 'on leave', 'out of office', 'ooh', 'vacation', 'holiday',
                              'absent', 'not feeling well'].freeze
    DATE_OVERRIDE_KEYWORDS = ['shift', 'shifted', 'reschedul', 'moved to', 'updated', 'update',
                              'changed to', 'next week', 'next day', 'replacement', 'revised'].freeze
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
      if attendance_only_request?(subject_text: subject_text, body_text: body_text)
        return Result.new(
          status: :flagged,
          reason: 'attendance_not_leave',
          user: user,
          leave_dates: [],
          leave_fraction: 0,
          leave_entries: [],
          date_source: :none,
          subject_has_explicit_date: false,
          body_has_explicit_date: false,
          used_sent_fallback: false
        )
      end

      leave_entries = extract_leave_entries(
        subject_text: subject_text,
        body_text: body_text,
        reference_time: reference_time
      )
      leave_fraction = leave_entries.map { |entry| entry[:fraction].to_f }.max || determine_leave_fraction(subject_text: subject_text, body_text: body_text)

      if cancellation_request?(subject_text: subject_text, body_text: body_text)
        cancellation_extraction = extract_dates_with_priority(
          subject_text: subject_text,
          body_text: body_text,
          reference_time: reference_time
        )
        return Result.new(
          status: :cancelled,
          reason: 'cancelled',
          user: user,
          leave_dates: cancellation_extraction[:dates],
          leave_fraction: leave_fraction,
          leave_entries: [],
          date_source: cancellation_extraction[:source],
          subject_has_explicit_date: cancellation_extraction[:subject_dates].any?,
          body_has_explicit_date: cancellation_extraction[:body_dates].any?,
          used_sent_fallback: false
        )
      end

      date_extraction = extract_dates_with_priority(
        subject_text: subject_text,
        body_text: body_text,
        reference_time: reference_time
      )
      extracted_dates = date_extraction[:dates]
      used_sent_fallback = false
      date_source = date_extraction[:source]
      subject_has_explicit_date = date_extraction[:subject_dates].any?
      body_has_explicit_date = date_extraction[:body_dates].any?

      fallback_date = reference_time&.to_date
      if extracted_dates.empty? && fallback_date
        extracted_dates = [fallback_date]
        date_source = :sent_fallback
        used_sent_fallback = true
      end

      if extracted_dates.empty?
        return Result.new(
          status: :flagged,
          reason: 'no_date_found',
          user: user,
          leave_dates: [],
          leave_fraction: leave_fraction,
          leave_entries: [],
          date_source: :none,
          subject_has_explicit_date: subject_has_explicit_date,
          body_has_explicit_date: body_has_explicit_date,
          used_sent_fallback: used_sent_fallback
        )
      end

      working_dates = extracted_dates.select { |date| RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(date) }.uniq.sort
      if working_dates.empty?
        return Result.new(
          status: :flagged,
          reason: 'no_working_day_found',
          user: user,
          leave_dates: extracted_dates.uniq.sort,
          leave_fraction: leave_fraction,
          leave_entries: [],
          date_source: date_source,
          subject_has_explicit_date: subject_has_explicit_date,
          body_has_explicit_date: body_has_explicit_date,
          used_sent_fallback: used_sent_fallback
        )
      end

      normalized_entries = normalize_leave_entries(leave_entries, working_dates, leave_fraction)
      Result.new(
        status: :confirmed,
        user: user,
        leave_dates: working_dates,
        leave_fraction: leave_fraction,
        leave_entries: normalized_entries,
        date_source: date_source,
        subject_has_explicit_date: subject_has_explicit_date,
        body_has_explicit_date: body_has_explicit_date,
        used_sent_fallback: used_sent_fallback
      )
    rescue StandardError
      Result.new(
        status: :flagged,
        reason: 'parse_error',
        leave_dates: [],
        leave_fraction: 0,
        leave_entries: [],
        date_source: :none,
        subject_has_explicit_date: false,
        body_has_explicit_date: false,
        used_sent_fallback: false
      )
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
      subject_normalized = normalize_date_text(subject_text).downcase
      body_normalized = normalize_date_text(primary_body_text(body_text)).downcase
      full_body_normalized = normalize_date_text(body_text).downcase

      return FULL_DAY_FRACTION if full_day_requested?(body_normalized) || full_day_requested?(full_body_normalized)
      return HALF_DAY_FRACTION if half_day_requested?(body_normalized)
      return FULL_DAY_FRACTION if full_day_requested?(subject_normalized)
      return HALF_DAY_FRACTION if half_day_requested?(subject_normalized)

      FULL_DAY_FRACTION
    end

    def determine_fraction_for_date(date, text, reference_text = '')
      # Determine fraction for a specific date by analyzing context around that date
      # For mixed emails like "Late Arrival on 17th & On Leave on 19th",
      # split by connectors to get separate contexts for each date
      
      # First try to find the date in separate contexts (split by & and "and")
      contexts = text.split(/\s+(?:and|\&)\s+/)
      
      normalized_full = normalize_date_text(text).downcase
      date_day = date.strftime('%d').to_i
      
      # Find which context block contains this date
      contexts.each do |context_block|
        normalized_ctx = normalize_date_text(context_block).downcase
        next unless normalized_ctx.match?(/\b#{date_day}\b/)
        
        # Found the context block for this date, check patterns here
        return FULL_DAY_FRACTION if normalized_ctx.match?(/on\s+leave.*#{date_day}\b/i)
        return FULL_DAY_FRACTION if normalized_ctx.match?(/#{date_day}\b.*on\s+leave/i)
        return FULL_DAY_FRACTION if normalized_ctx.match?(/sick\s+leave/i)
        return FULL_DAY_FRACTION if normalized_ctx.match?(/full\s+day/i)
        
        return HALF_DAY_FRACTION if normalized_ctx.match?(/late\s+arrival/i)
        return HALF_DAY_FRACTION if normalized_ctx.match?(/late\b/i)
        return HALF_DAY_FRACTION if normalized_ctx.match?(/half\s+day/i)
        return HALF_DAY_FRACTION if normalized_ctx.match?(/morning/i)
        return HALF_DAY_FRACTION if normalized_ctx.match?(/evening/i)
        
        # If no specific marker found in this context, check if it mentions leave generally
        return FULL_DAY_FRACTION if normalized_ctx.match?(/leave|vacation|absent/i)
        
        # Default for this context
        return FULL_DAY_FRACTION
      end
      
      # If date not found in split contexts, try whole text with more conservative patterns
      return FULL_DAY_FRACTION if full_day_requested?(normalized_full)
      return HALF_DAY_FRACTION if half_day_requested?(normalized_full)
      
      FULL_DAY_FRACTION  # Default to full day
    end

    def extract_leave_entries(subject_text:, body_text:, reference_time:)
      # STATEFUL PARSING: Track current date and apply fractions to it
      # When date changes (shifted to X), update tracking
      # When fraction changes (full/half day), apply to last tracked date
      
      combined_text = "#{subject_text}\n#{primary_body_text(body_text)}"
      # Keep unnormalized for date extraction (preserves ordinals like "17th")
      combined_unnormalized = combined_text
      # Normalized for keyword analysis
      normalized = normalize_date_text(combined_text).downcase
      
      # Extract all dates in order they appear (use UNNORMALIZED text to preserve ordinals)
      all_dates = extract_dates_in_order(combined_unnormalized, reference_time)
      return [] if all_dates.empty?
      
      # For simple case: single date in subject
      subject_dates = extract_dates_from_text(
        normalize_date_text(subject_text),
        reference_time
      )
      
      # Determine if body overrides with a new date
      body_dates = extract_dates_from_text(
        normalize_date_text(primary_body_text(body_text)),
        reference_time
      )
      
      # Build entries: use body date if it exists and has shift keywords, else subject date
      tracking_date = if body_dates.any? && DATE_OVERRIDE_KEYWORDS.any? { |kw| normalized.include?(kw) }
                        body_dates.first  # Use first body date when shift detected
                      elsif subject_dates.any?
                        subject_dates.first
                      else
                        all_dates.first
                      end
      
       # Determine fraction for this date
      # Priority: Check body's leave context first, then subject
      fraction = determine_leave_fraction(subject_text: subject_text, body_text: body_text)
      
      # Detect explicit date ranges (from X to Y, between X and Y, etc.)
      # Only expand to full range if range pattern is explicitly present
      range_pattern = /(?:from|between|through|to)\s+\d+|(?:to|through|-|and|&)\s+\d+/i
      has_explicit_range = combined_unnormalized.match?(range_pattern) && all_dates.length > 1
      
      # Expand date ranges if explicit range pattern AND multiple dates
      shift_detected = body_dates.any? && DATE_OVERRIDE_KEYWORDS.any? { |kw| normalized.include?(kw) }
      target_dates = if shift_detected
                        # When shift detected, only use the new date (tracking_date)
                        [tracking_date]
                      elsif has_explicit_range && all_dates.last - all_dates.first > 0
                        # Multiple dates with explicit range: expand the range
                        (all_dates.first..all_dates.last).to_a
                      elsif all_dates.length > 1
                        # Multiple dates WITHOUT explicit range: use each date separately
                        all_dates
                      else
                        # Single date (possibly with shifts/clarifications)
                        [tracking_date]
                      end
      
      # For multiple separate dates (mixed attendance/leave), determine fraction per date
      # For ranges or single date, use global fraction
      if !has_explicit_range && target_dates.length > 1
        # Mixed dates like "Late Arrival on 17th & On Leave on 19th"
        # Determine fraction for each date contextually
        target_dates.map do |date|
          date_fraction = determine_fraction_for_date(date, subject_text, combined_unnormalized)
          { date: date, fraction: date_fraction }
        end
      else
        # Single date or explicit range: use global fraction
        target_dates.map { |date| { date: date, fraction: fraction } }
      end
    rescue StandardError => e
      Rails.logger.warn("LeaveEmailParser#extract_leave_entries error: #{e.message}")
      []
    end

    def extract_dates_in_order(text, reference_time)
      # Extract dates maintaining order of appearance
      dates = []
      
      # Pattern 1: MONTH DAY (e.g., "February 19" or "Feb 19")
      text.scan(/\b(#{MONTH_REGEX})\s+(\d{1,2})(?:,\s*(\d{4}))?\b/i) do |match|
        month_str, day_str, year_str = match
        year = year_str&.to_i || reference_time&.year || Date.today.year
        begin
          date = Date.parse("#{month_str} #{day_str}, #{year}")
          dates << date if date
        rescue StandardError
          next
        end
      end
      
      # Pattern 2: DAY MONTH (e.g., "19 February" or "19 Feb")
      text.scan(/\b(\d{1,2})\s+(#{MONTH_REGEX})(?:\s+(\d{4}))?\b/i) do |match|
        day_str, month_str, year_str = match
        year = year_str&.to_i || reference_time&.year || Date.today.year
        begin
          date = Date.parse("#{month_str} #{day_str}, #{year}")
          dates << date if date
        rescue StandardError
          next
        end
      end
      
      # Pattern 3: DD/MM/YYYY or DD.MM.YYYY patterns
      text.scan(/\b(\d{1,2})[\/.\/](\d{1,2})[\/.\/](\d{4})\b/) do |match|
        day, month, year = match.map(&:to_i)
        begin
          # Prefer DD/MM/YYYY for this organization
          date = Date.new(year, month, day)
          dates << date if date
        rescue ArgumentError
          next
        end
      end
      
      # Pattern 4: Ordinal dates without month (e.g., "17th", "19th", "5th")
      # When no month specified, infer from reference_time (email date)
      # This handles cases like "Late Arrival on 17th & On Leave on 19th" sent on Feb 15
      ref_month = reference_time&.month || Date.today.month
      ref_year = reference_time&.year || Date.today.year
      text.scan(/\b(\d{1,2})(?:st|nd|rd|th)\b/i) do |match|
        day = match[0].to_i
        next if day < 1 || day > 31
        
        # Check if this day is already in our dates (avoid duplicates)
        next if dates.any? { |d| d.day == day }
        
        begin
          date = Date.new(ref_year, ref_month, day)
          dates << date if date
        rescue ArgumentError
          # If day doesn't exist in inferred month (e.g., 31st in Feb), skip
          next
        end
      end
      
      dates.uniq.sort
    end

    def extract_dates_with_priority(subject_text:, body_text:, reference_time:)
      subject_dates = extract_dates_from_text(leave_focused_text(subject_text), reference_time)
      body_text = body_text.to_s
      body_dates = extract_dates_from_text(leave_focused_text(primary_body_text(body_text)), reference_time)
      return { dates: body_dates, source: :body, subject_dates: subject_dates, body_dates: body_dates } if body_override_subject?(body_text, subject_dates, body_dates)
      if subject_dates.any? && body_dates.any?
        return body_dates.max > subject_dates.max ? { dates: body_dates, source: :body, subject_dates: subject_dates, body_dates: body_dates } :
                                                    { dates: subject_dates, source: :subject, subject_dates: subject_dates, body_dates: body_dates }
      end
      return { dates: subject_dates, source: :subject, subject_dates: subject_dates, body_dates: body_dates } if subject_dates.any?
      return { dates: body_dates, source: :body, subject_dates: subject_dates, body_dates: body_dates } if body_dates.any?

      { dates: [], source: :none, subject_dates: subject_dates, body_dates: body_dates }
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
      normalized = normalize_date_text(text.to_s)

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

      dates = dates.compact.map { |date| normalize_extracted_date(date, reference_time) }.compact.uniq.sort
      dates = expand_ranges(normalized, dates, reference_time)
      return dates if dates.any?

      chronic_dates = extract_dates_with_chronic(normalized, reference_time)
      chronic_dates = chronic_dates.map { |date| normalize_extracted_date(date, reference_time) }.compact.uniq.sort
      return chronic_dates if chronic_dates.any?

      extract_dates_with_nickel(normalized, reference_time).map { |date| normalize_extracted_date(date, reference_time) }.compact.uniq.sort
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
      # Guard: Only use Chronic if text has explicit date-like keywords
      # This prevents false positives like "full day leave" → today's date
      return [] unless has_date_keywords?(text)

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

    def has_date_keywords?(text)
      normalized = text.downcase
      
      # Exclude pure leave-description phrases (no temporal context)
      # Examples: "full day leave", "half day", "afternoon", "evening"
      if /\A(full\s+)?day|half\s+day|morning|afternoon|evening|first\s+half|second\s+half\z/i.match?(normalized)
        return false
      end
      
      # Check for explicit date keywords
      /\b(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|
           aug|august|sep|september|oct|october|nov|november|dec|december|
           mon|monday|tue|tuesday|wed|wednesday|thu|thursday|fri|friday|sat|saturday|sun|sunday|
           today|tomorrow|yesterday|next|previous|last|
           \d+(?:st|nd|rd|th))\b/ix.match?(normalized) ||
        /\b(from|to|between|through|until)\b/i.match?(normalized) ||
        /\d+\s*(hours?|hrs?|days?)/i.match?(normalized)
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

    def parse_year_first_date(candidate)
      parts = candidate.split(/[\/.]/).map(&:to_i)
      return nil if parts.length != 3

      year, month, day = parts
      Date.new(year, month, day)
    rescue ArgumentError
      nil
    end

    def normalize_extracted_date(date, reference_time)
      return date if reference_time.nil? || date.nil?

      reference_date = reference_time.to_date
      return date if date.year == reference_date.year

      candidate = Date.new(reference_date.year, date.month, date.day)
      return candidate if (candidate - reference_date).abs < (date - reference_date).abs

      date
    rescue ArgumentError
      date
    end

    def normalize_date_text(text)
      text.to_s
          .gsub(/\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/, '\1/\2/\3')
          .gsub(/\b(\d{1,2})(st|nd|rd|th)\b/i, '\1')
    end

    def attendance_only_request?(subject_text:, body_text:)
      normalized = [normalize_date_text(subject_text), normalize_date_text(primary_body_text(body_text))]
                    .compact.join("\n").downcase
      return false unless ATTENDANCE_KEYWORDS.any? { |keyword| normalized.include?(keyword) }

      !LEAVE_CONTEXT_KEYWORDS.any? { |keyword| normalized.include?(keyword) }
    end

    def full_day_requested?(text)
      FULL_DAY_KEYWORDS.any? { |keyword| text.include?(keyword) }
    end

    def half_day_requested?(text)
      HALF_DAY_KEYWORDS.any? { |keyword| text.include?(keyword) }
    end

    def body_override_subject?(body_text, subject_dates, body_dates)
      return false unless body_dates.any? && subject_dates.any?

      normalized_body = normalize_date_text(body_text).downcase
      DATE_OVERRIDE_KEYWORDS.any? { |keyword| normalized_body.include?(keyword) }
    end

    def leave_focused_text(text)
      normalized = normalize_date_text(text.to_s)
      segments = normalized
                 .split(/(?:\n|[.!?;]|&|\bbut\b|\band\b)/i)
                 .map(&:strip)
                 .reject(&:empty?)
      focused_segments = segments.select { |segment| leave_context_segment?(segment) }
      focused_segments.any? ? focused_segments.join("\n") : normalized
    end

    def leave_context_segment?(segment)
      normalized = segment.downcase
      DATE_OVERRIDE_KEYWORDS.any? { |keyword| normalized.include?(keyword) } ||
        LEAVE_CONTEXT_KEYWORDS.any? { |keyword| normalized.include?(keyword) } ||
        HALF_DAY_KEYWORDS.any? { |keyword| normalized.include?(keyword) } ||
        FULL_DAY_KEYWORDS.any? { |keyword| normalized.include?(keyword) }
    end

    def extract_leave_entries_from_text(text, reference_time)
      normalized = normalize_date_text(text.to_s)
      segments = normalized
                 .split(/(?:\n|[.!?;]|&|\bbut\b|\band\b)/i)
                 .map(&:strip)
                 .reject(&:empty?)

      entries = []
      segments.each do |segment|
        segment_dates = extract_dates_from_text(segment, reference_time)
        next if segment_dates.empty?

        fraction = determine_leave_fraction_for_segment(segment)
        segment_dates.each do |date|
          entries << { date: date, fraction: fraction, source: segment }
        end
      end

      entries = entries.empty? ? extract_dates_from_text(normalized, reference_time).map do |date|
        { date: date, fraction: determine_leave_fraction(subject_text: normalized, body_text: normalized), source: normalized }
      end : entries

      entries
    end

    def normalize_leave_entries(entries, working_dates, fallback_fraction)
      grouped = {}
      entries.each do |entry|
        date = entry[:date]
        next if date.nil? || !working_dates.include?(date)

        grouped[date] ||= []
        grouped[date] << entry[:fraction].to_f
      end

      working_dates.map do |date|
        fraction = grouped[date]&.max || fallback_fraction
        { date: date, fraction: fraction.to_f }
      end
    end

    def determine_leave_fraction_for_segment(segment)
      normalized = normalize_date_text(segment).downcase
      return FULL_DAY_FRACTION if full_day_requested?(normalized)
      return HALF_DAY_FRACTION if half_day_requested?(normalized)

      FULL_DAY_FRACTION
    end

    def expand_ranges(text, dates, reference_time)
      return dates if dates.length < 2

      expanded = dates.dup
      text.scan(/(#{date_token_regex})\s*(?:to|-)\s*(#{date_token_regex})/i).each do |start_token, end_token|
        start_date = normalize_extracted_date(safe_parse_date_token(start_token), reference_time)
        end_date = normalize_extracted_date(safe_parse_date_token(end_token), reference_time)
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
