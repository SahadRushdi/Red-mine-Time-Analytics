# frozen_string_literal: true

require 'digest'

# Caches raw time entries fetched from the external ("support") Redmine instance so the
# "My Team" effective-time column does not pay the 3-5s HTTP cost on every render.
#
# One row caches the normalized entries for a single (base_url, project_identifier, from, to)
# tuple. The fetch is grouping-independent (grouping/aggregation happens locally in
# RedmineTimeAnalytics::ExternalRedmineTimeService), so a single cached row is reused across
# every grouping, chart type, view mode, team and pagination change for that date range.
#
# Freshness is served stale-while-revalidate: web requests always read the stored payload
# immediately; ExternalTimeCacheScheduler#sweep! refreshes stale rows in the background
# (current ranges every 10 min, past ranges every 24h) and prunes rows that stop being read.
class TaExternalTimeCache < ActiveRecord::Base
  # Rails 8 removed the positional `serialize :payload, JSON` API. The public JSON
  # attribute type works with the text column used by both Rails 6.1 and Rails 8.
  attribute :payload, :json

  # Hardcoded defaults (see plan: config exposed as constants, no admin UI).
  CURRENT_RANGE_REFRESH = 10.minutes
  PAST_RANGE_REFRESH = 24.hours
  CLEANUP_AFTER = 7.days

  def self.entry_key_for(base_url, identifier, from, to)
    Digest::SHA1.hexdigest("#{base_url}|#{identifier}|#{from}|#{to}")
  end

  # Returns the normalized entries array for one external project + range.
  # Cache hit  -> returns the stored payload immediately (and bumps last_accessed_at).
  # Cache miss -> yields (inline external fetch), persists the result, and returns it.
  def self.fetch_or_store(base_url:, identifier:, from:, to:)
    key = entry_key_for(base_url, identifier, from, to)
    row = find_by(entry_key: key)
    if row
      row.touch_access!
      return row.entries
    end

    entries = yield
    upsert_entries!(key: key, identifier: identifier, from: from, to: to, entries: entries)
    entries
  end

  # Background sweep: refresh stale rows, then prune rows no longer being read.
  def self.sweep!
    return unless TaTeamSetting.support_redmine_configured?

    service = build_service
    find_each { |row| refresh_row!(row, service) if row.stale? }
    cleanup!
  end

  def self.cleanup!
    where('last_accessed_at IS NULL OR last_accessed_at < ?', CLEANUP_AFTER.ago).delete_all
  end

  # Refetch a single row from the external Redmine. Claims the row under a short row lock
  # (bumping refreshed_at so concurrent workers skip it) then fetches outside the lock so the
  # slow HTTP call never holds a DB transaction open.
  def self.refresh_row!(row, service = nil)
    claimed = row.with_lock do
      next false unless row.stale?

      row.update_column(:refreshed_at, Time.current)
      true
    end
    return unless claimed

    service ||= build_service
    entries = service.fetch_entries(project_identifier: row.project_identifier, from: row.from_date, to: row.to_date)
    row.update!(payload: Array(entries))
  rescue StandardError => e
    Rails.logger.warn("[TaExternalTimeCache] refresh failed for #{row.entry_key}: #{e.message}")
  end

  def self.build_service
    config = TaTeamSetting.support_redmine_settings
    RedmineTimeAnalytics::ExternalRedmineTimeService.new(base_url: config[:base_url], api_key: config[:api_key])
  end

  def self.upsert_entries!(key:, identifier:, from:, to:, entries:)
    row = find_or_initialize_by(entry_key: key)
    row.project_identifier = identifier
    row.from_date = from
    row.to_date = to
    row.payload = Array(entries)
    row.refreshed_at = Time.current
    row.last_accessed_at = Time.current
    row.save!
    row
  rescue ActiveRecord::RecordNotUnique
    # Another worker stored the same key concurrently; the existing row is good enough.
    find_by(entry_key: key)
  end

  def entries
    Array(payload)
  end

  def touch_access!
    update_column(:last_accessed_at, Time.current)
  end

  # A range that still includes today is treated as "current" and refreshed aggressively;
  # a range entirely in the past rarely changes and is refreshed slowly.
  def current_range?
    to_date.present? && to_date >= Date.current
  end

  def refresh_interval
    current_range? ? CURRENT_RANGE_REFRESH : PAST_RANGE_REFRESH
  end

  def stale?
    refreshed_at.nil? || refreshed_at < refresh_interval.ago
  end
end
