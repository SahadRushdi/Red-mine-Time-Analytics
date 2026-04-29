RedmineApp::Application.routes.draw do
  get 'time_analytics', to: 'time_analytics#index'
  get 'my/time', to: 'time_analytics#individual_dashboard', as: :my_time
  get 'time_analytics/custom_dashboard', to: 'time_analytics#custom_dashboard'
  post 'time_analytics/export_csv', to: 'time_analytics#export_csv'
  
  get 'time_entry_panel', to: 'time_entry_panel#index', as: :time_entry_panel
  get 'time_entry_panel/activities/:issue_id', to: 'time_entry_panel#get_activities', as: :time_entry_panel_activities
  post 'time_entry_panel/create', to: 'time_entry_panel#create_time_entry', as: :create_time_entry_panel
  patch 'time_entry_panel/entry/:id', to: 'time_entry_panel#update_entry', as: :tep_entry_update
  delete 'time_entry_panel/entry/:id', to: 'time_entry_panel#destroy_entry', as: :tep_entry_destroy
  
  resources :custom_holidays do
    collection do
      post :import_csv
    end
  end
  # Team Analytics routes (separate controller)
  get 'team/analytics', to: 'team_analytics#index', as: :team_analytics
  post 'team/analytics/export_csv', to: 'team_analytics#export_csv', as: :team_analytics_export_csv
  get 'team/analytics/tree_data', to: 'team_analytics#get_tree_data', as: :team_analytics_tree_data

  # Admin routes for Team Analytics Configuration
  resources :admin_ta_teams, path: 'admin/ta_teams' do
    collection do
      post :validate_url
      post :assign_member
    end
    resources :admin_ta_team_memberships, path: 'memberships', as: 'memberships', only: [:create, :update, :destroy]
    resources :admin_ta_team_projects, path: 'projects', as: 'team_projects'
  end

  resources :admin_ta_hiring_needs, path: 'admin/ta_hiring_needs', only: [:index, :create, :update, :destroy] do
    member do
      patch :mark_filled
      patch :mark_open
    end
  end
  resources :admin_ta_hiring_titles, path: 'admin/ta_hiring_titles', only: [:create, :destroy]
  resource :admin_ta_team_settings, path: 'admin/ta_team_settings', only: [:index, :create, :destroy] do
    get :index, on: :collection
    post :sync_leave_inbox, on: :collection
  end
  
  resources :custom_holidays do
    collection do
      post :import_csv
    end
  end
end
