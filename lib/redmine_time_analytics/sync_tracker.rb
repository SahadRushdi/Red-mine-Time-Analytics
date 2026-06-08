# frozen_string_literal: true

module RedmineTimeAnalytics
  class SyncTracker
    attr_reader :sync_id

    def initialize(sync_id)
      @sync_id = sync_id
    end

    def update(message:, progress:)
      Rails.cache.write(
        cache_key,
        { status: 'processing', message: message, progress: progress.to_i },
        expires_in: 60.minutes
      )
    end

    def complete(message:)
      Rails.cache.write(
        cache_key,
        { status: 'completed', message: message, progress: 100 },
        expires_in: 60.minutes
      )
    end

    def fail(error:)
      Rails.cache.write(
        cache_key,
        { status: 'failed', error: error, progress: 0 },
        expires_in: 60.minutes
      )
    end

    def self.get(sync_id)
      Rails.cache.read("leave_sync_#{sync_id}")
    end

    private

    def cache_key
      "leave_sync_#{@sync_id}"
    end
  end
end
