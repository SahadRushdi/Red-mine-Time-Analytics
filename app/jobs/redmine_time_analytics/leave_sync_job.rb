# frozen_string_literal: true

module RedmineTimeAnalytics
  class LeaveSyncJob
    include SuckerPunch::Job

    def perform(sync_mode, sync_id)
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          settings = TaTeamSetting.leave_sync_settings
          tracker = RedmineTimeAnalytics::SyncTracker.new(sync_id)
          RedmineTimeAnalytics::LeaveSyncService.new(settings: settings, tracker: tracker).sync!(mode: sync_mode)
        rescue StandardError => e
          Rails.logger.error("[LeaveSyncJob] Background sync failed: #{e.message}\n#{e.backtrace.join("\n")}")
          RedmineTimeAnalytics::SyncTracker.new(sync_id).fail(error: e.message)
        end
      end
    end
  end
end
