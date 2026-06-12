# frozen_string_literal: true

require 'rufus-scheduler'

module RedmineTimeAnalytics
  # Periodically refreshes TaExternalTimeCache rows in the background so the "My Team"
  # effective-time column stays warm. Mirrors the structure of LeaveSyncScheduler.
  #
  # The sweep runs every few minutes but only refetches rows whose freshness window has
  # elapsed (current ranges: 10 min, past ranges: 24h — see TaExternalTimeCache), so it is
  # cheap when nothing is stale.
  class ExternalTimeCacheScheduler
    SWEEP_CRON = '*/5 * * * *'

    @mutex = Mutex.new
    @scheduler = nil
    @job = nil

    class << self
      def start
        return if scheduler_disabled?

        @mutex.synchronize do
          return if @scheduler

          @scheduler = Rufus::Scheduler.new
          @job = @scheduler.cron(SWEEP_CRON) { run_sweep! }
        end
      end

      private

      def run_sweep!
        ActiveRecord::Base.connection_pool.with_connection do
          TaExternalTimeCache.sweep!
        end
      rescue StandardError => e
        Rails.logger.error("[ExternalTimeCacheScheduler] sweep failed: #{e.message}")
      end

      def scheduler_disabled?
        ENV['EXTERNAL_TIME_CACHE_SCHEDULER_DISABLED'].to_s == '1' || File.basename($PROGRAM_NAME) == 'rake'
      end
    end
  end
end
