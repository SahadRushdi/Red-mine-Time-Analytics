# frozen_string_literal: true

module RedmineTimeAnalytics
  class LeaveFetcherFactory
    def self.build(settings)
      RedmineTimeAnalytics::LeaveProviders::GmailOauthProvider.new(settings)
    end
  end
end
