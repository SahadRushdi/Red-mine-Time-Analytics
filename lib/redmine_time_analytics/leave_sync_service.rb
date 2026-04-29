# frozen_string_literal: true

module RedmineTimeAnalytics
  class LeaveSyncService
    SyncResult = Struct.new(:processed_count, :imported_count, :flagged_count, :errors, keyword_init: true)

    def initialize(settings: TaTeamSetting.leave_sync_settings)
      @settings = settings
      @parser = RedmineTimeAnalytics::LeaveEmailParser.new
      @fetcher = RedmineTimeAnalytics::GmailLeaveFetcher.new(@settings)
    end

    def sync!(mode: :incremental)
      recipient_email = @settings[:recipient_email]
      raise 'Leave recipient email is required' if recipient_email.blank?

      messages = @fetcher.fetch_messages(
        mode: mode,
        recipient_email: recipient_email,
        historical_start_date: @settings[:historical_sync_start_date],
        synced_after: (mode.to_s == 'historical' ? nil : @settings[:last_synced_at])
      )

      result = SyncResult.new(processed_count: 0, imported_count: 0, flagged_count: 0, errors: [])
      messages.each do |message|
        result.processed_count += 1
        handle_message(message, recipient_email, mode, result)
      rescue StandardError => e
        result.errors << e.message
      end

      TaTeamSetting.update_leave_sync_runtime!(
        last_synced_at: Time.zone.now,
        last_sync_mode: mode.to_s
      )

      result
    end

    private

    def handle_message(message, recipient_email, mode, result)
      parsed = @parser.parse(message: message, recipient_email: recipient_email)
      return if parsed.status == :ignored

      if parsed.status == :flagged
        persist_flagged_message(parsed, message, mode)
        result.flagged_count += 1
        return
      end

      parsed.leave_dates.each do |leave_date|
        TaLeaveRecord.upsert_from_email!(
          user: parsed.user,
          leave_date: leave_date,
          leave_fraction: parsed.leave_fraction,
          status: 'confirmed',
          sender_email: message[:from],
          recipient_email: message[:to],
          source_message_id: message[:message_id],
          source_thread_id: message[:thread_id],
          source_sent_at: message[:sent_at],
          raw_subject: message[:subject],
          raw_body: message[:body],
          sync_mode: mode.to_s
        )
      end
      result.imported_count += parsed.leave_dates.length
    end

    def persist_flagged_message(parsed, message, mode)
      return unless parsed.user

      TaLeaveRecord.upsert_from_email!(
        user: parsed.user,
        leave_date: message[:sent_at].to_date,
        leave_fraction: 0,
        status: 'flagged',
        sender_email: message[:from],
        recipient_email: message[:to],
        source_message_id: message[:message_id],
        source_thread_id: message[:thread_id],
        source_sent_at: message[:sent_at],
        raw_subject: "[FLAGGED] #{message[:subject]}",
        raw_body: message[:body],
        sync_mode: mode.to_s
      )
    end
  end
end
