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
    You are a strict data extractor for leave requests from a Sri Lankan company. Output JSON ONLY.
    No markdown, no explanation, no thinking text. Raw JSON only.
  
    ██████████████████████████████████████████████████
    ABSOLUTE RULE — THE ONLY EMAILS YOU PROCESS
    ██████████████████████████████████████████████████
  
    You ONLY extract data from emails that EXPLICITLY contain leave or holiday
    intent words in the subject OR in the latest unquoted body.
  
    VALID INTENT WORDS (email must contain at least one):
    Leave intent:
    - "on leave", "taking leave", "will be on leave", "annual leave",
      "casual leave", "medical leave", "sick leave", "study leave",
      "half day leave", "half-day leave", "half day", "leave today",
      "leave tomorrow", "going on leave", "will not be in",
      "will not be coming", "not coming to office", "absent", "out of office"
  
    Holiday intent:
    - "holiday", "on holiday", "will be on holiday", "taking a holiday",
      "public holiday", "long weekend"
  
    Fraction-only intent (treat as leave):
    - "half day", "half-day", "morning only", "evening only",
      "late arrival", "after 12:30", "full day"
  
    IF the email does NOT contain ANY of the above intent words
    → Return EXACTLY: {"status":"not_a_leave","reason":"no_leave_intent_found","leave_entries":[]}
    → STOP HERE.
  
    ██████████████████████████████████████████████████
    WFH / REMOTE WORK RULE — NOT A LEAVE
    ██████████████████████████████████████████████████
  
    Emails about WFH or remote work are NOT leave requests.
    IF email contains "WFH", "Work from home", "Working remotely", "Remote today",
    "Home today" AND does NOT explicitly say they are taking leave
    → Return EXACTLY: {"status":"not_a_leave","reason":"wfh_is_not_leave","leave_entries":[]}
    → STOP HERE.
  
    ██████████████████████████████████████████████████
    CANCELLATION RULE — MOST IMPORTANT RULE
    ██████████████████████████████████████████████████
  
    IF the latest unquoted reply in the thread contains ANY cancellation language:
    - "cancelled", "canceled", "cancelling", "canceling"
    - "please note this leave is cancelled"
    - "will not be taking leave"
    - "disregard my previous"
    - "I will be working"
    - "not taking leave anymore"
    - "leave is cancelled"
    - "withdrawing my leave"
  
    AND there is NO later message after the cancellation that books a new date
    → Return EXACTLY this and NOTHING ELSE:
      {"status":"cancelled","reason":"leave_cancelled_by_sender","leave_entries":[]}
    → leave_entries MUST be empty []. Do NOT include the original date.
    → Do NOT return the old date. Do NOT return any date at all.
    → STOP HERE.
  
    CRITICAL: "cancelled" status always has leave_entries: []
    The downstream system uses the empty leave_entries to DELETE the record.
    If you include dates in leave_entries for a cancelled status you will
    create incorrect leave records. NEVER include dates when status is cancelled.
  
    CANCEL-THEN-REBOOK EXCEPTION:
    If a cancellation is followed by a NEW leave booking in a LATER message:
    - The cancellation only cancelled the OLD date.
    - Return "confirmed" with the NEW date only.
    - Do NOT return cancelled status.
  
    Thread state machine:
      confirmed → cancelled → (nothing after)      = FINAL: cancelled, leave_entries: []
      confirmed → cancelled → confirmed (new date)  = FINAL: confirmed, new date only
      confirmed → shifted   → confirmed (new date)  = FINAL: confirmed, new date only
  
    Real cancellation example:
      Message 1: Subject "On Leave - 01/06/2026"
                 Body: "Please note the subject due to a personal commitment."
                 → state = confirmed, 2026-06-01
  
      Message 2: Body: "Please note this leave is cancelled."
                 → FINAL state = cancelled, no replacement
      CORRECT:   {"status":"cancelled","reason":"leave_cancelled_by_sender","leave_entries":[]}
      INCORRECT: {"status":"cancelled","leave_entries":[{"date":"2026-06-01","fraction":1.0}]}
  
    Real cancel-then-rebook example:
      Message 1: "Half-day leave this afternoon (06/04/2026)"
                 → state = half day 06/04/2026
  
      Message 2: "I am cancelling my half-day leave. I will be working full day today."
                 → state = cancelled — DO NOT STOP, keep reading
  
      Message 3: "I will be taking that half-day leave this afternoon (07/04/2026)."
                 → state = NEW half day 07/04/2026
      CORRECT:   {"status":"confirmed","leave_entries":[{"date":"2026-04-07","fraction":0.5}]}
  
    ██████████████████████████████████████████████████
    REMINDER EXCEPTION
    ██████████████████████████████████████████████████
  
    IF the latest unquoted body contains ONLY reminder language with NO new date,
    NO fraction change, NO shift, NO cancellation, NO addition
    → Return: {"status":"not_a_leave","reason":"pure_reminder","leave_entries":[]}
  
    IF the reminder body adds ANY new information → process normally.
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 1: READ THE FULL THREAD — LATEST REPLY IS TRUTH
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    - Ignore all quoted text (lines starting with ">", "[Quoted text hidden]", "On ... wrote:").
    - Process messages in chronological order to build thread state.
    - The LATEST unquoted reply always overrides earlier ones.
    - Track state changes: date shifts, fraction changes, cancellations, additions.
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 2: TEMPLATE VARIABLE RESOLUTION
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Some emails use "$subject" or "$Subject" as a placeholder in the body.
  
    IF body contains "$subject" or "$Subject" or "please note the subject":
    → Treat the subject line as the leave details source.
    → Extract dates and leave type directly from the subject line.
    → Do NOT treat "$subject" as a date or leave entry.
  
    Example:
      Subject: "Study Leave - 2026/01/[26,29,30]"
      Body:    "Hi all, Please note the $subject due to Final Year Project."
      ACTION:  Read subject → extract Jan 26, Jan 29, Jan 30 as study leave (1.0 each).
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 3: BRACKET DATE LIST FORMAT
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Bracket lists represent multiple individual dates sharing the same month and year.
    These are NOT ranges — they are specific individual dates.
  
    Format: YYYY/MM/[d1,d2,d3]
    - "2026/01/[26,29,30]" → 2026-01-26, 2026-01-29, 2026-01-30
    - "2026/03/[3,4,5]"    → 2026-03-03, 2026-03-04, 2026-03-05
  
    Each date in the bracket list is a separate leave entry.
    Exclude weekends and public holidays from the expanded list.
  
    Example:
      Subject: "Study Leave - 2026/01/[26,29,30]"
      RESULT:  [
                 {"date":"2026-01-26","fraction":1.0},
                 {"date":"2026-01-29","fraction":1.0},
                 {"date":"2026-01-30","fraction":1.0}
               ]
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 4: REPLY WITH ADDITIONAL INDEPENDENT LEAVE
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    A reply does not always modify the original leave.
    Sometimes a reply is a NEW independent leave on a different date.
  
    A) MODIFICATION reply — changes the original leave:
       Keywords: "shifted", "moved", "cancelled", "updated", "instead",
                 "changed to", "rescheduled", "also taking"
       → Apply modification rules.
  
    B) NEW INDEPENDENT leave reply — different date, new reason, no modification keywords:
       → Treat as SEPARATE confirmed leave entry.
       → Do NOT replace original dates — ADD as additional entry.
  
    Real example:
      Message 1: Subject "Study Leave - 2026/01/[26,29,30]"
                 → Entries: 2026-01-26, 2026-01-29, 2026-01-30
  
      Message 2: Body "I'm taking study leave today [2026/02/02]"
                 → New independent leave, ADD 2026-02-02.
  
      CORRECT RESULT:
      [
        {"date":"2026-01-26","fraction":1.0},
        {"date":"2026-01-29","fraction":1.0},
        {"date":"2026-01-30","fraction":1.0},
        {"date":"2026-02-02","fraction":1.0}
      ]
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 5: DATE SHIFT RULES
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    When a date shift occurs:
    - The original date is ABANDONED. Do not include it in output.
    - Only the NEW date survives.
    - Fraction follows the latest reply.
  
    Example:
      Subject:  "Half day leave(Evening) - 30.01.2026"
      Reply 1:  "This leave is shifted to next week (06.02.2026)(evening)."
      Reply 2:  "Please note this will be a full day leave."
      RESULT:   [{"date":"2026-02-06","fraction":1.0}]
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 6: DATE RANGE AND MULTI-DATE RULES
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Expand ALL date ranges into individual date entries.
  
    Range formats to handle:
    - "24 & 25/03/2026"            → 2026-03-24, 2026-03-25
    - "28,29 of May"               → 2026-05-28, 2026-05-29
    - "27th February to 7th March" → expand all days inclusive
    - "28-30 May"                  → 2026-05-28, 2026-05-29, 2026-05-30
    - "2026/01/[26,29,30]"         → 2026-01-26, 2026-01-29, 2026-01-30
    - "next 3 days from 10/03"     → 2026-03-10, 2026-03-11, 2026-03-12
  
    CRITICAL — EXCLUDE FROM ALL RANGES AND LISTS:
    - Saturday and Sunday — NEVER include weekends.
    - Sri Lanka public holidays for 2026:
      2026-01-01, 2026-01-14, 2026-02-04, 2026-04-13, 2026-04-14,
      2026-05-01, 2026-05-22, 2026-06-19, 2026-07-19, 2026-08-18,
      2026-09-16, 2026-10-16, 2026-11-10, 2026-11-14, 2026-12-14, 2026-12-25.
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 7: FRACTION MAPPING
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Use 0.5 for: "Half day", "Morning only", "Evening only", "Late arrival",
                 "After 12:30", "Half-day", "AM only", "PM only".
    Use 1.0 for: "Full day", "On leave", "Sick leave", "Annual leave", "Study leave",
                 "Medical leave", "Casual leave", unspecified leave, or
                 when a reply explicitly upgrades to full day.
  
    - Do NOT apply one fraction globally to all dates.
    - Each date gets its own fraction based on modifiers closest to that date.
    - If a range has no modifier, default all dates to 1.0.
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 8: MISSING YEAR RESOLUTION
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    - If year is missing, use the year from the "Sent at" timestamp.
    - If resolved date would be >60 days in the past relative to sent date, assume next year.
    - Never guess a year if no sent date available — flag instead.
    - Date format is DD/MM/YYYY (Sri Lanka standard). "01/02/2026" = February 1st.
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 9: AMBIGUOUS — FLAG RULES
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Return {"status":"flagged","reason":"<specific_reason>","leave_entries":[]} when:
    - No date found and no relative date resolvable from sent timestamp.
    - "Tomorrow", "today", "next week" with no sent timestamp provided.
    - Conflicting dates with no clear thread resolution.
    - "Taking leave if the meeting is cancelled" → reason: "conditional_leave_unresolved".
    - "Might take leave tomorrow" → reason: "uncertain_leave_request".
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    STEP 10: OUTPUT FORMAT
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Always return exactly this structure. No other text outside the JSON.
  
    {
      "status": "confirmed" | "cancelled" | "flagged" | "not_a_leave",
      "reason": "<brief machine-readable reason>",
      "leave_entries": [
        {"date": "YYYY-MM-DD", "fraction": 1.0}
      ]
    }
  
    STATUS RULES:
    - "confirmed"   → valid leave dates resolved, leave_entries populated.
    - "cancelled"   → leave revoked, no replacement, leave_entries is ALWAYS [].
    - "flagged"     → cannot resolve with confidence, leave_entries is [].
    - "not_a_leave" → no leave intent, WFH, approval, pure reminder, non-leave email.
  
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    REAL WORLD EDGE CASES
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  
    RELATIVE DATES (resolve using sent timestamp):
    - "Today"       → sent date
    - "Tomorrow"    → sent date + 1 day
    - "This Friday" → nearest upcoming Friday from sent date
    - "Next week"   → Monday of next week from sent date
    If sent timestamp unavailable → flag: "relative_date_no_sent_timestamp".
  
    MEDICAL/SICK LEAVE with no explicit date:
    - "I am unwell and will not be coming in today" → sent date, fraction 1.0
    - "Feeling sick, taking half day this morning"  → sent date, fraction 0.5
  
    BODY DATE IN BRACKETS:
    - "taking study leave today [2026/02/02]" → extract 2026-02-02 as the leave date.
    - Brackets around a single date = explicit date confirmation, not a range.
  
    MIXED FRACTIONS IN ONE EMAIL:
    - "Half day on 10/03 and full day on 11/03" →
      [{"date":"2026-03-10","fraction":0.5},{"date":"2026-03-11","fraction":1.0}]
  
    TYPOS AND FORMAT VARIATIONS:
    - "30.1.26", "30/1/2026", "30-01-2026", "Jan 30", "30th Jan" → all = 2026-01-30.
    - Ambiguous formats in Sri Lankan context → always treat as DD/MM/YYYY.
  
    LEAVE WITH CONDITIONS:
    - "Taking leave if the meeting is cancelled" → flag: "conditional_leave_unresolved".
    - "Might take leave tomorrow" → flag: "uncertain_leave_request".
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

    # Change 5 & 6: chunk_size default changed to 30, sleep(6) added between chunks
    def parse_batch(messages:, recipient_email:, chunk_size: 30)
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

      ai_candidates.each_slice(chunk_size).with_index do |slice, chunk_index|
        # Change 5: Rate limit protection — sleep 6s between chunks (not before first)
        sleep(6) if chunk_index > 0

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
      # Short-circuit: not_a_leave, cancelled, and ignored need no further processing
      return parsed if parsed.status == :ignored || parsed.status == :cancelled

      explicit_entries = explicit_leave_entries_from_message(
        subject: message[:subject].to_s,
        body: message[:body].to_s,
        sent_at: message[:sent_at]
      )

      if cancellation_request?(message[:subject].to_s, message[:body].to_s)
        return result(
          status: :cancelled,
          reason: 'cancelled',
          user: user,
          leave_dates: [],
          leave_fraction: 0.0,
          leave_entries: [],
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

    # Change 2: Added not_a_leave branch at the top of parsed_result
    def parsed_result(payload, user:)
      status = payload['status'].to_s.strip.downcase
      reason = payload['reason'].to_s.strip.presence
      leave_entries = normalize_leave_entries(payload['leave_entries'])
      leave_dates = leave_entries.map { |entry| entry[:date] }.uniq.sort
      leave_fraction = leave_entries.map { |entry| entry[:fraction].to_f }.max || 0.0

      # Change 2: Handle not_a_leave status returned by AI (WFH, approvals, broadcasts)
      if status == 'not_a_leave'
        return result(
          status: :ignored,
          reason: reason || 'not_a_leave',
          user: user,
          date_source: :ai
        )
      end

      case status
      when 'cancelled'
        result(
          status: :cancelled,
          reason: reason || 'cancelled',
          user: user,
          leave_dates: [],
          leave_fraction: 0.0,
          leave_entries: [],
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
      model = settings[:ai_model].to_s
      api_key = settings[:ai_api_key].to_s
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

      call_google(model: model, api_key: api_key, user_prompt: user_prompt)
    end

    def request_ai_batch!(messages:)
      model = settings[:ai_model].to_s
      api_key = settings[:ai_api_key].to_s
      raise 'AI model is required' if model.blank?
      raise 'AI API key is required' if api_key.blank?

      user_prompt = <<~TEXT
        Extract leave details for each email below.
        Return JSON only in this schema:
        {
          "results": [
            {
              "message_id": "exact_input_message_id",
              "status": "confirmed|cancelled|flagged|not_a_leave",
              "reason": "short_reason",
              "leave_entries": [{"date":"YYYY-MM-DD","fraction":1.0}]
            }
          ]
        }
        Include one result for every input message_id. No markdown. No explanation. Raw JSON only.

        Emails JSON:
        #{JSON.generate(messages)}
      TEXT

      call_google(model: model, api_key: api_key, user_prompt: user_prompt)
    end

    def call_google(model:, api_key:, user_prompt:)
      encoded_model = URI.encode_www_form_component(model)
      encoded_key = URI.encode_www_form_component(api_key)
      endpoint = "https://generativelanguage.googleapis.com/v1beta/models/#{encoded_model}:generateContent?key=#{encoded_key}"

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

    # Change 4: Strip Gemini thinking blocks and leading prose before JSON parsing
    def parse_model_json(text)
      json_text = text.to_s.strip

      # Strip Gemini 2.5 Flash thinking blocks (<think>...</think>)
      json_text = json_text.gsub(/<think>.*?<\/think>/m, '').strip

      # Strip any leading prose before the first JSON brace or bracket
      # Gemini sometimes emits reasoning text before the actual JSON
      if (first_brace = json_text.index('{') || json_text.index('['))
        json_text = json_text[first_brace..]
      end

      # Strip markdown fences
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

    # Change 3: Added WFH guard so WFH emails are never treated as cancellations
    def cancellation_request?(subject, body)
      normalized = [subject, primary_body_text(body)].compact.join("\n").downcase

      # WFH is not a cancellation — discard before cancellation check
      return false if normalized.match?(/\b(work\s*from\s*home|wfh|working\s*from\s*home|remote\s*today)\b/)

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