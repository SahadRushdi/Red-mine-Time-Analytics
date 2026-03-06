RedmineApp::Application.routes.draw do
  get 'time_analytics', to: 'time_analytics#index'
  get 'my/time', to: 'time_analytics#individual_dashboard', as: :my_time
  get 'time_analytics/team_dashboard', to: 'time_analytics#team_dashboard'
  get 'time_analytics/custom_dashboard', to: 'time_analytics#custom_dashboard'
  post 'time_analytics/export_csv', to: 'time_analytics#export_csv'
  
  get 'time_entry_panel', to: 'time_entry_panel#index', as: :time_entry_panel
  get 'time_entry_panel/activities/:issue_id', to: 'time_entry_panel#get_activities', as: :time_entry_panel_activities
  post 'time_entry_panel/create', to: 'time_entry_panel#create_time_entry', as: :create_time_entry_panel
  
  resources :custom_holidays
end