# frozen_string_literal: true

require 'rufus-scheduler'
require 'fugit'

module RedmineTimeAnalytics
  class MissingTimeScheduler
    # Hard-coded end-of-month reminder: fires every Friday 18:00 and only acts when that Friday is
    # the last Friday of the month (gated inside the service). Deliberately not admin-configurable.
    #
    # No timezone here on purpose - it is appended dynamically in `monthly_cron` below. Rufus::
    # Scheduler's `timezone:` constructor option is NOT inherited by individual #cron jobs:
    # Rufus::Scheduler::CronJob#initialize parses the cron line with `Fugit::Cron.do_parse(cronline)`
    # and never passes the scheduler's own opts/timezone into it (see rufus-scheduler's
    # lib/rufus/scheduler/jobs_repeat.rb). A cron string with no embedded zone is therefore parsed
    # with @zone/@timezone == nil, and Fugit falls back to UTC - so this job silently fired at
    # 23:30 IST instead of 18:00 IST. Every other (working) cron in this plugin already embeds its
    # own zone (e.g. "50 15 * * 5 Asia/Kolkata"); this one must too.
    MONTHLY_REMINDER_TIME = '0 18 * * 5'

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

        cron_exprs = settings[:crons] + [monthly_cron(settings[:timezone])]
        times = cron_exprs.filter_map do |cron|
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

      # The monthly cron, with the timezone explicitly embedded in the string (see the comment on
      # MONTHLY_REMINDER_TIME for why this can't just rely on the scheduler's own timezone option).
      def monthly_cron(timezone)
        tz = timezone.to_s.strip.presence || TaTeamSetting::DEFAULT_MISSING_TIME_TIMEZONE
        "#{MONTHLY_REMINDER_TIME} #{tz}"
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

        @jobs << @scheduler.cron(monthly_cron(settings[:timezone])) { run_notification!(period: :monthly) }
      end

      def run_notification!(period: nil)
        result = RedmineTimeAnalytics::MissingTimeNotificationService.new.notify_missing_time!(period: period)
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
