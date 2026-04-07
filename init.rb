Redmine::Plugin.register :redmine_time_analytics do
  name 'Redmine Time Analytics Plugin'
  author 'Sahad'
  description 'Comprehensive time tracking analytics and reporting for Redmine'
  version '1.0.0'
  url 'http://example.com/path/to/plugin'
  author_url 'http://example.com/about'

  # Add to top menu
  menu :top_menu, :time_analytics, { controller: 'time_analytics', action: 'index' }, 
       caption: :label_time_analytics, after: :my_page

  # Add to admin menu
  menu :admin_menu, :custom_holidays, { controller: 'custom_holidays', action: 'index' },
       caption: 'Holidays',
       html: { class: 'icon', style: 'background-image: url(/images/calendar.png)' }

  # Add permissions
  project_module :time_analytics do
    permission :view_time_analytics, { time_analytics: [:index, :individual_dashboard] }
  end
end

Rails.configuration.to_prepare do
  next unless ENV['RTA_RUN_REMINDER_ON_SERVER_BOOT'] == '1'

  begin
    RedmineTimeAnalytics::WeeklyTimeLogReminder.run!(force_run: true)
    Rails.logger.info('[redmine_time_analytics] Weekly reminder executed at server boot (forced).')
  rescue => e
    Rails.logger.error("[redmine_time_analytics] Weekly reminder boot execution failed: #{e.class} - #{e.message}")
  end
end
