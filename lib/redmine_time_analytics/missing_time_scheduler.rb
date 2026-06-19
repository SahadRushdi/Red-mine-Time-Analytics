# frozen_string_literal: true

require 'rufus-scheduler'
require 'fugit'

module RedmineTimeAnalytics
  class MissingTimeScheduler
    @mutex = Mutex.new
    @scheduler = nil
    @jobs = []

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

        times = settings[:crons].filter_map do |cron|
          line = cron_line_for(cron)
          next_t = line&.next_time(from_time)
          next unless next_t

          next_t.respond_to?(:to_t) ? next_t.to_t : next_t.to_time
        end

        times.min
      end

      def cron_line_for(cron)
        Fugit::Cron.parse(cron.to_s)
      rescue StandardError
        nil
      end

      private

      def schedule_current!
        @jobs.each do |job|
          if job.respond_to?(:unschedule)
            job.unschedule
          else
            @scheduler.unschedule(job)
          end
        end
        @jobs = []

        settings = TaTeamSetting.missing_time_settings
        return unless settings[:enabled]

        settings[:crons].each do |cron|
          next if cron.blank?

          job = @scheduler.cron cron do
            run_notification!
          end
          @jobs << job
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
