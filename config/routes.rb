RedmineApp::Application.routes.draw do
  get 'time_analytics', to: 'time_analytics#index'
  get 'my/time', to: 'time_analytics#individual_dashboard', as: :my_time
  get 'time_analytics/custom_dashboard', to: 'time_analytics#custom_dashboard'
  post 'time_analytics/export_csv', to: 'time_analytics#export_csv'
  
  # Team Analytics routes (separate controller)
  get 'team/analytics', to: 'team_analytics#index', as: :team_analytics
  post 'team/analytics/export_csv', to: 'team_analytics#export_csv', as: :team_analytics_export_csv

  # Admin routes for Team Analytics Configuration
  resources :admin_ta_teams, path: 'admin/ta_teams' do
    collection do
      post :validate_url
    end
    resources :admin_ta_team_memberships, path: 'memberships', as: 'memberships'
    resources :admin_ta_team_projects, path: 'projects', as: 'team_projects'
  end
  
  resource :admin_ta_team_settings, path: 'admin/ta_team_settings', only: [:index, :create, :destroy] do
    get :index, on: :collection
  end
  
  resources :custom_holidays
end