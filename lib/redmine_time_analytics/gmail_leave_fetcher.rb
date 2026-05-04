# frozen_string_literal: true

module RedmineTimeAnalytics
  # Backward-compatible alias for existing integrations.
  class GmailLeaveFetcher < RedmineTimeAnalytics::LeaveProviders::GmailDwdProvider
  end
end
