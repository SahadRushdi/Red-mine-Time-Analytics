# frozen_string_literal: true

require 'rufus-scheduler'
require 'fugit'

module RedmineTimeAnalytics
  class MissingTimeScheduler
    @mutex = Mutex.new
    @scheduler = nil
    @job = nil

    class << self
      def start
        return if scheduler_disabled?

        @mutex.synchronize do
          return if @scheduler

          @scheduler = Rufus::Scheduler.new(timezone: scheduler_timezone)
          schedule_current!
        end
      end

      def refresh!
        return if scheduler_disabled?

        @mutex.synchronize do
          @scheduler ||= Rufus::Scheduler.new(timezone: scheduler_timezone)
          schedule_current!
        end
      end

      def next_run_at(settings: TaTeamSetting.missing_time_settings, from_time: Time.zone.now)
        return nil unless settings[:enabled]

        cron_line = cron_line_for(settings[:cron])
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

        settings = TaTeamSetting.missing_time_settings
        return unless settings[:enabled]
        return if settings[:cron].blank?

        @job = @scheduler.cron settings[:cron] do
          run_notification!
        end
      end

      def run_notification!
        result = RedmineTimeAnalytics::MissingTimeNotificationService.new.notify_missing_time!
        if result.errors.any?
          unique_errors = result.errors.uniq
          Rails.logger.warn(
            "[MissingTimeScheduler] completed with #{result.errors.length} errors " \
            "(#{unique_errors.length} unique): #{unique_errors.first(10).join(' | ')}"
          )
        end
        result
      rescue StandardError => e
        # Log but do not re-raise to avoid crashing scheduler. Errors are captured in result where possible.
        Rails.logger.error("[MissingTimeScheduler] failed: #{e.class}: #{e.message}")
        nil
      end

      def scheduler_timezone
        TaTeamSetting.missing_time_settings[:timezone]
      end

      def scheduler_disabled?
        ENV['MISSING_TIME_SCHEDULER_DISABLED'].to_s == '1' || File.basename($PROGRAM_NAME) == 'rake'
      end
    end
  end
end
