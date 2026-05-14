# frozen_string_literal: true

require_relative 'leave_email_parser'
require_relative 'simple_leave_email_parser'
require_relative 'ai_leave_extractor'
require_relative 'hybrid_leave_extractor'

module RedmineTimeAnalytics
  class LeaveSyncService
    AI_BATCH_CHUNK_SIZE = 50
    SyncResult = Struct.new(:processed_count, :imported_count, :flagged_count, :errors, keyword_init: true)

    def initialize(settings: TaTeamSetting.leave_sync_settings)
      @settings = settings
      @extractor = RedmineTimeAnalytics::HybridLeaveExtractor.new(settings: @settings)
      @fetcher = RedmineTimeAnalytics::LeaveFetcherFactory.build(@settings)
    end

    def sync!(mode: :incremental)
      recipient_email = @settings[:recipient_email]
      raise 'Leave recipient email is required' if recipient_email.blank?

      messages = @fetcher.fetch_messages(
        mode: mode,
        recipient_email: recipient_email,
        historical_start_date: @settings[:historical_sync_start_date],
        historical_end_date: @settings[:historical_sync_end_date],
        synced_after: (mode.to_s == 'historical' ? nil : @settings[:last_synced_at])
      )

      result = process_messages!(messages: messages, recipient_email: recipient_email, mode: mode)

      TaTeamSetting.update_leave_sync_runtime!(
        last_synced_at: Time.zone.now,
        last_sync_mode: mode.to_s
      )

      result
    end

    def sync_messages!(messages:, mode: :push, recipient_email: nil)
      effective_recipient = recipient_email.to_s.strip.presence || @settings[:recipient_email]
      raise 'Leave recipient email is required' if effective_recipient.blank?

      result = process_messages!(messages: messages, recipient_email: effective_recipient, mode: mode)
      TaTeamSetting.update_leave_sync_runtime!(
        last_synced_at: Time.zone.now,
        last_sync_mode: mode.to_s
      )
      result
    end

    private

    def process_messages!(messages:, recipient_email:, mode:)
      result = SyncResult.new(processed_count: 0, imported_count: 0, flagged_count: 0, errors: [])
      sorted = sorted_messages(messages)
      sorted.each_slice(AI_BATCH_CHUNK_SIZE) do |chunk|
        parsed_batch =
          if @extractor.respond_to?(:parse_batch)
            @extractor.parse_batch(
              messages: chunk,
              recipient_email: recipient_email,
              chunk_size: AI_BATCH_CHUNK_SIZE
            )
          else
            chunk.map { |message| @extractor.parse(message: message, recipient_email: recipient_email) }
          end
        chunk.each_with_index do |message, index|
          result.processed_count += 1
          handle_message(message, recipient_email, mode, result, parsed: parsed_batch[index])
        rescue StandardError => e
          result.errors << e.message
        end
      end
      result
    end

    def handle_message(message, recipient_email, mode, result, parsed: nil)
      parsed ||= @extractor.parse(message: message, recipient_email: recipient_email)
      return if parsed.status == :ignored
      sent_at = normalized_sent_time(message[:sent_at])

      if parsed.status == :flagged
        persist_flagged_message(parsed, message, recipient_email, mode, sent_at)
        result.flagged_count += 1
        return parsed
      end

      if parsed.status == :cancelled
        handle_cancelled_message(parsed, message, sent_at)
        return parsed
      end

      return if newer_thread_message?(parsed.user, message, sent_at)

      leave_entries = parsed_leave_entries(parsed)
      leave_entries = preserve_latest_thread_dates_if_needed(parsed, message, sent_at, leave_entries)
      reconcile_thread_entries(parsed, message, sent_at, leave_entries)
      persisted_sync_mode = persisted_sync_mode(mode, parsed.date_source == :ai)
      leave_entries.each do |entry|
        TaLeaveRecord.upsert_from_email!(
          user: parsed.user,
          leave_date: entry[:date],
          leave_fraction: entry[:fraction],
          status: 'confirmed',
          sender_email: message[:from],
          recipient_email: recipient_email,
          source_message_id: message[:message_id],
          source_thread_id: message[:thread_id],
          source_sent_at: sent_at,
          raw_subject: message[:subject],
          raw_body: message[:body],
          sync_mode: persisted_sync_mode
        )
      end
      result.imported_count += 1 if leave_entries.any?
      parsed
    end

    def persist_flagged_message(parsed, message, recipient_email, mode, sent_at)
      leave_date = parsed.leave_dates.first || sent_at&.to_date || Time.zone.now.to_date
      TaLeaveRecord.upsert_from_email!(
        user: parsed.user,
        leave_date: leave_date,
        leave_fraction: parsed.leave_fraction.to_f,
        status: 'flagged',
        sender_email: message[:from],
        recipient_email: recipient_email,
        source_message_id: message[:message_id],
        source_thread_id: message[:thread_id],
        source_sent_at: sent_at,
        raw_subject: "[FLAGGED:#{parsed.reason}] #{message[:subject]}",
        raw_body: message[:body],
        sync_mode: persisted_sync_mode(mode, parsed.date_source == :ai)
      )
    end

    def handle_cancelled_message(parsed, message, sent_at)
      return unless parsed.user

      thread_id = message[:thread_id].to_s
      if thread_id.present?
        TaLeaveRecord.cancel_thread_records!(
          user_id: parsed.user.id,
          thread_id: thread_id,
          incoming_sent_at: sent_at,
          leave_dates: parsed.leave_dates
        )
      else
        TaLeaveRecord.cancel_user_dates!(user_id: parsed.user.id, leave_dates: parsed.leave_dates)
      end
    end

    def newer_thread_message?(user, message, sent_at)
      return false unless user && message[:thread_id].present?

      TaLeaveRecord.newer_thread_update_exists?(
        user_id: user.id,
        thread_id: message[:thread_id],
        incoming_sent_at: sent_at
      )
    end

    def reconcile_thread_entries(parsed, message, sent_at, leave_entries)
      return unless parsed.user && message[:thread_id].present?

      dates = leave_entries.map { |entry| entry[:date] }
      TaLeaveRecord.replace_thread_records!(
        user_id: parsed.user.id,
        thread_id: message[:thread_id],
        incoming_sent_at: sent_at,
        leave_dates: dates
      )

      TaLeaveRecord.reconcile_thread_entries!(
        user_id: parsed.user.id,
        thread_id: message[:thread_id],
        incoming_sent_at: sent_at,
        leave_entries: leave_entries
      )
    end

    def parsed_leave_entries(parsed)
      entries = Array(parsed.leave_entries)
      return entries if entries.any?

      parsed.leave_dates.map do |leave_date|
        { date: leave_date, fraction: parsed.leave_fraction.to_f }
      end
    end

    def preserve_latest_thread_dates_if_needed(parsed, message, sent_at, leave_entries)
      return leave_entries unless parsed.user && message[:thread_id].present?
      return leave_entries unless leave_entries.any?

      latest_entries = TaLeaveRecord.latest_thread_entries(
        user_id: parsed.user.id,
        thread_id: message[:thread_id],
        before_sent_at: sent_at
      )
      return leave_entries unless latest_entries.any?

      incoming_dates = leave_entries.map { |entry| entry[:date] }.compact.uniq.sort
      latest_dates = latest_entries.map { |entry| entry[:date] }.compact.uniq.sort
      return latest_entries.map { |entry| { date: entry[:date], fraction: parsed.leave_fraction.to_f } } if parsed.used_sent_fallback

      latest_date = latest_dates.max
      incoming_date = incoming_dates.max
      return leave_entries if incoming_date.present? && latest_date.present? && incoming_date > latest_date

      latest_entries.map do |entry|
        { date: entry[:date], fraction: parsed.leave_fraction.to_f }
      end
    end

    def sorted_messages(messages)
      Array(messages)
        .map { |message| message.symbolize_keys }
        .sort_by { |message| [normalized_sent_time(message[:sent_at]) || Time.zone.at(0), message[:message_id].to_s] }
    end

    def normalized_sent_time(value)
      return value.in_time_zone if value.respond_to?(:in_time_zone)

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def persisted_sync_mode(mode, ai_analyzed)
      base = case mode.to_s
             when 'historical'
               'historical'
             when 'incremental'
               'incremental'
             when 'push', 'google_apps_script_push'
               'push'
             else
               mode.to_s[0, 16]
             end
      ai_analyzed ? "#{base}_ai" : base
    end

  end
end
