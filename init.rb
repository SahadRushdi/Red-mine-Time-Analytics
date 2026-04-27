require File.expand_path('lib/redmine_time_analytics/external_redmine_time_service', __dir__)

Redmine::Plugin.register :redmine_time_analytics do
  name 'Redmine Time Analytics Plugin'
  author 'Sahad Rushdi'
  description 'Comprehensive time tracking analytics and reporting for Redmine'
  version '3.0.0'
  url 'https://github.com/SahadRushdi/Red-mine-Time-Analytics'
  settings default: {}

  # Add to top menu
  menu :top_menu, :time_analytics, { controller: 'time_analytics', action: 'index' }, 
       caption: :label_time_analytics, after: :my_page

  # Add Team Analytics menu (visible to team leads and super users)
  menu :top_menu, :team_analytics,
       { controller: 'team_analytics', action: 'index' },
       caption: 'My Team',
       if: Proc.new { User.current.logged? && User.current.can_access_team_analytics? },
       after: :time_analytics

  # Add to admin menu
  menu :admin_menu, :team_analytics_configuration, { controller: 'admin_ta_teams', action: 'index' },
       caption: 'Teams',
       html: { class: 'icon', style: 'background-image: url(/images/group.png)' }

  # Add to admin menu
  menu :admin_menu, :positions_hiring, { controller: 'admin_ta_hiring_needs', action: 'index' },
       caption: 'Positions & Hiring',
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
