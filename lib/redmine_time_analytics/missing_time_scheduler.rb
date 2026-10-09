# frozen_string_literal: true

require 'rufus-scheduler'
require 'fugit'

module RedmineTimeAnalytics
  class MissingTimeScheduler
    # Previous-month compliance reminder, on the first at 18:00. Each cron must embed its
    # timezone because Rufus does not inherit the scheduler's timezone for individual jobs.
    MONTHLY_REMINDER_TIME = '0 18 1 * *'

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

        cron_exprs = active_schedules(settings).map { |schedule| schedule[:cron] } + [monthly_cron(settings[:timezone])]
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

      def active_schedules(settings)
        schedules = settings[:schedules] || Array(settings[:crons]).map { |cron| { cron: cron, weekly: true, daily: false } }
        schedules.select { |schedule| schedule[:cron].present? && (schedule[:weekly] || schedule[:daily]) }
      end

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

        active_schedules(settings).each do |schedule|
          job = @scheduler.cron schedule[:cron] do
            run_notification!(period: :weekly) if schedule[:weekly]
            run_notification!(period: :daily) if schedule[:daily]
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
        ENV['MISSING_TIME_SCHEDULER_DISABLED'].to_s == '1' ||
          File.basename($PROGRAM_NAME) == 'rake' ||
          (defined?(Rails) && Rails.env.test?)
      end
    end
  end
end
