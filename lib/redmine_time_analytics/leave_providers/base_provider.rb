# frozen_string_literal: true

module RedmineTimeAnalytics
  module LeaveProviders
    class BaseProvider
      def initialize(settings)
        @settings = settings
      end

      def fetch_messages(mode:, recipient_email:, historical_start_date:, historical_end_date:, synced_after:)
        raise NotImplementedError, 'Provider must implement fetch_messages'
      end

      private

      attr_reader :settings
    end
  end
end
