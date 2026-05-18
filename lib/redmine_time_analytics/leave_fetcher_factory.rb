# frozen_string_literal: true

module RedmineTimeAnalytics
  class LeaveFetcherFactory
    def self.build(settings)
      approach = settings[:leave_approach].to_s
      case approach
      when 'dwd'
        RedmineTimeAnalytics::LeaveProviders::GmailDwdProvider.new(settings)
      when 'google_apps_script'
        RedmineTimeAnalytics::LeaveProviders::GoogleAppsScriptProvider.new(settings)
      else
        RedmineTimeAnalytics::LeaveProviders::GmailOauthProvider.new(settings)
      end
    end
  end
end
