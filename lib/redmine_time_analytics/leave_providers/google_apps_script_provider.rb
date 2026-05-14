# frozen_string_literal: true

module RedmineTimeAnalytics
  module LeaveProviders
    class GoogleAppsScriptProvider < BaseProvider
      def fetch_messages(mode:, recipient_email:, historical_start_date:, historical_end_date:, synced_after:)
        raise 'Google Apps Script approach is push-based. Use the webhook endpoint instead of manual mailbox sync.'
      end
    end
  end
end
