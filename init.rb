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

  # Add Team Analytics menu (only visible to team leads)
  menu :top_menu, :team_analytics,
       { controller: 'team_analytics', action: 'index' },
       caption: 'My Team',
       if: Proc.new { User.current.logged? && User.current.is_team_lead? },
       after: :time_analytics

  # Add to admin menu
  menu :admin_menu, :team_analytics_configuration, { controller: 'admin_ta_teams', action: 'index' },
       caption: 'Team Analytics Configuration',
       html: { class: 'icon', style: 'background-image: url(/images/group.png)' }

  # Add to admin menu
  menu :admin_menu, :custom_holidays, { controller: 'custom_holidays', action: 'index' },
       caption: 'Holidays',
       html: { class: 'icon', style: 'background-image: url(/images/calendar.png)' }

  # Add permissions
  project_module :time_analytics do
    permission :view_time_analytics, { time_analytics: [:index, :individual_dashboard] }
  end
end