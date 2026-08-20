# frozen_string_literal: true

require 'rufus-scheduler'
require 'fugit'

module RedmineTimeAnalytics
  class LeaveSyncScheduler
    @mutex = Mutex.new
    @scheduler = nil
    @job = nil

    class << self
      def start
        return if scheduler_disabled?

        @mutex.synchronize do
          return if @scheduler

          @scheduler = Rufus::Scheduler.new
          schedule_current!
        end
      end

      def refresh!
        return if scheduler_disabled?

        @mutex.synchronize do
          @scheduler ||= Rufus::Scheduler.new
          schedule_current!
        end
      end

      def next_run_at(settings: TaTeamSetting.leave_sync_settings, from_time: Time.zone.now)
        return nil unless settings[:enabled] && TaTeamSetting.leave_sync_configured?

        cron = settings[:cron].presence || TaTeamSetting.default_leave_sync_cron
        cron_line = cron_line_for(cron)
        next_time = cron_line&.next_time(from_time)
        return nil unless next_time

        return next_time.to_t if next_time.respond_to?(:to_t)
        return next_time.to_time if next_time.respond_to?(:to_time)

        next_time
      end

      def cron_line_for(cron)
        Fugit::Cron.parse(cron.to_s)
      rescue StandardError
        nil
      end

      private

      def schedule_current!
        if @job
          if @job.respond_to?(:unschedule)
            @job.unschedule
          else
            @scheduler.unschedule(@job)
          end
        end
        @job = nil

        settings = TaTeamSetting.leave_sync_settings
        return unless settings[:enabled] && TaTeamSetting.leave_sync_configured?

        cron = settings[:cron].presence || TaTeamSetting.default_leave_sync_cron
        @job = @scheduler.cron cron do
          run_sync!
        end
      end

      def run_sync!
        result = RedmineTimeAnalytics::LeaveSyncService.new.sync!(mode: :incremental)
        if result.errors.any?
          unique_errors = result.errors.uniq
          Rails.logger.warn(
            "[LeaveSyncScheduler] completed with #{result.errors.length} errors " \
            "(#{unique_errors.length} unique): #{unique_errors.first(10).join(' | ')}"
          )
        end
        result
      rescue StandardError => e
        Rails.logger.error("[LeaveSyncScheduler] failed: #{e.message}")
        raise
      end

      def scheduler_disabled?
        ENV['LEAVE_SYNC_SCHEDULER_DISABLED'].to_s == '1' ||
          File.basename($PROGRAM_NAME) == 'rake' ||
          (defined?(Rails) && Rails.env.test?)
      end
    end
  end
end
