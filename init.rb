require File.expand_path('lib/redmine_time_analytics/external_redmine_time_service', __dir__)
require File.expand_path('lib/redmine_time_analytics/leave_email_parser', __dir__)
require File.expand_path('lib/redmine_time_analytics/simple_leave_email_parser', __dir__)
require File.expand_path('lib/redmine_time_analytics/ai_leave_extractor', __dir__)
require File.expand_path('lib/redmine_time_analytics/hybrid_leave_extractor', __dir__)
require File.expand_path('lib/redmine_time_analytics/leave_providers/base_provider', __dir__)
require File.expand_path('lib/redmine_time_analytics/leave_providers/gmail_base_provider', __dir__)
require File.expand_path('lib/redmine_time_analytics/leave_providers/gmail_oauth_provider', __dir__)
require File.expand_path('lib/redmine_time_analytics/leave_providers/gmail_dwd_provider', __dir__)
require File.expand_path('lib/redmine_time_analytics/leave_providers/google_apps_script_provider', __dir__)
require File.expand_path('lib/redmine_time_analytics/leave_fetcher_factory', __dir__)
require File.expand_path('lib/redmine_time_analytics/gmail_leave_fetcher', __dir__)
require File.expand_path('lib/redmine_time_analytics/sync_tracker', __dir__)
require File.expand_path('app/jobs/redmine_time_analytics/leave_sync_job', __dir__)
require File.expand_path('lib/redmine_time_analytics/leave_sync_service', __dir__)
require File.expand_path('lib/redmine_time_analytics/leave_sync_scheduler', __dir__)
require File.expand_path('lib/redmine_time_analytics/missing_time_email_template', __dir__)
require File.expand_path('lib/redmine_time_analytics/missing_time_notification_service', __dir__)
require File.expand_path('lib/redmine_time_analytics/missing_time_scheduler', __dir__)
require File.expand_path('lib/redmine_time_analytics/external_time_cache_scheduler', __dir__)
require File.expand_path('app/mailers/missing_time_mailer', __dir__)
require File.expand_path('lib/redmine_time_analytics/activity_groups_hook', __dir__)

# User Title query/report patches (module definitions; applied after the register block below)
require File.expand_path('lib/redmine_time_analytics/user_patch', __dir__)
require File.expand_path('lib/redmine_time_analytics/time_entry_patch', __dir__)
require File.expand_path('lib/redmine_time_analytics/issue_patch', __dir__)
require File.expand_path('lib/redmine_time_analytics/time_entry_query_patch', __dir__)
require File.expand_path('lib/redmine_time_analytics/issue_query_patch', __dir__)
require File.expand_path('lib/redmine_time_analytics/time_report_patch', __dir__)

Redmine::Plugin.register :redmine_time_analytics do
  name 'Redmine Time Analytics Plugin'
  author 'Sahad Rushdi'
  description 'Comprehensive time tracking analytics and reporting for Redmine'
  version '3.0.1'
  url 'https://github.com/SahadRushdi/Red-mine-Time-Analytics'
  requires_redmine version_or_higher: '5.0.0'
  settings partial: 'redmine_time_analytics_settings',
           default: {
             'missing_time_recipients' => '',
             'missing_time_crons'      => []
           }

  # Add to top menu
  menu :top_menu, :time_analytics, { controller: 'time_analytics', action: 'index' }, 
       caption: :label_time_analytics, after: :my_page

  # Add Team Analytics menu (visible to team leads and super users, even if they are not assigned to a team)
  menu :top_menu, :team_analytics,
       { controller: 'team_analytics', action: 'index' },
       caption: 'My Team',
       if: Proc.new { User.current.logged? && User.current.can_access_team_analytics? },
       after: :time_analytics

  menu :top_menu, :leaves,
       { controller: 'leaves', action: 'index' },
       caption: :label_leaves,
       if: Proc.new { User.current.logged? && User.current.admin? },
       after: :team_analytics

  # Add to admin menu
  menu :admin_menu, :team_analytics_configuration, { controller: 'admin_ta_teams', action: 'index' },
       caption: 'Teams',
       html: { class: 'icon', style: 'background-image: url(/images/group.png)' }

  # Add to admin menu
  menu :admin_menu, :positions_hiring, { controller: 'admin_ta_hiring_needs', action: 'index' },
       caption: 'Positions & Hiring',
       html: { class: 'icon', style: 'background-image: url(/images/user.png)' }

  # Add to admin menu
  menu :admin_menu, :titles, { controller: 'admin_ta_titles', action: 'index' },
       caption: 'Titles',
       html: { class: 'icon', style: 'background-image: url(/images/user.png)' }

  # Add to admin menu
  menu :admin_menu, :custom_holidays, { controller: 'custom_holidays', action: 'index' },
       caption: 'Holidays',
       html: { class: 'icon', style: 'background-image: url(/images/calendar.png)' }

  menu :admin_menu, :leave_count_configuration, { controller: 'admin_leave_count', action: 'index' },
       caption: :label_leave_count_settings,
       html: { class: 'icon', style: 'background-image: url(/images/time.png)' }

  # Add permissions
  project_module :time_analytics do
    permission :view_time_analytics, { time_analytics: [:index, :individual_dashboard] }
  end

  Rails.application.config.after_initialize do
    RedmineTimeAnalytics::LeaveSyncScheduler.start
    RedmineTimeAnalytics::MissingTimeScheduler.start
    RedmineTimeAnalytics::ExternalTimeCacheScheduler.start

    Setting.after_commit(on: %i[create update]) do
      if name == 'plugin_redmine_time_analytics'
        RedmineTimeAnalytics::MissingTimeScheduler.refresh!
      end
    end
  end
end

# Apply User Title patches to core (reloadable) classes.
# Redmine's PluginLoader runs this init.rb inside a `to_prepare` block (see
# lib/redmine/plugin_loader.rb), so this code re-runs on every dev reload — exactly
# when the reloadable core classes need re-patching. The include?/included_modules
# guards make re-application idempotent.
User.include(RedmineTimeAnalytics::UserPatch) unless
  User.included_modules.include?(RedmineTimeAnalytics::UserPatch)
TimeEntry.include(RedmineTimeAnalytics::TimeEntryPatch) unless
  TimeEntry.included_modules.include?(RedmineTimeAnalytics::TimeEntryPatch)
Issue.include(RedmineTimeAnalytics::IssuePatch) unless
  Issue.included_modules.include?(RedmineTimeAnalytics::IssuePatch)
TimeEntryQuery.prepend(RedmineTimeAnalytics::TimeEntryQueryPatch) unless
  TimeEntryQuery.include?(RedmineTimeAnalytics::TimeEntryQueryPatch)
IssueQuery.prepend(RedmineTimeAnalytics::IssueQueryPatch) unless
  IssueQuery.include?(RedmineTimeAnalytics::IssueQueryPatch)
Redmine::Helpers::TimeReport.prepend(RedmineTimeAnalytics::TimeReportPatch) unless
  Redmine::Helpers::TimeReport.include?(RedmineTimeAnalytics::TimeReportPatch)
