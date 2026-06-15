RedmineApp::Application.routes.draw do
  get 'time_analytics', to: 'time_analytics#index'
  get 'my/time', to: 'time_analytics#individual_dashboard', as: :my_time
  get 'time_analytics/custom_dashboard', to: 'time_analytics#custom_dashboard'
  post 'time_analytics/export_csv', to: 'time_analytics#export_csv'
  get 'leaves', to: 'leaves#index', as: :leaves
  get 'leaves/data', to: 'leaves#data', as: :leaves_data
  post 'leaves', to: 'leaves#create', as: :leaves_create
  delete 'leaves', to: 'leaves#destroy_all', as: :leaves_destroy_all
  delete 'leaves/bulk_destroy', to: 'leaves#bulk_destroy', as: :leaves_bulk_destroy
  patch 'leaves/:id', to: 'leaves#update', as: :leave_update
  patch 'leaves/:id/status', to: 'leaves#update_status', as: :leave_status
  delete 'leaves/:id', to: 'leaves#destroy', as: :leave_destroy
  
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
  get 'team/analytics/period_members', to: 'team_analytics#get_period_team_members', as: :team_analytics_period_members

  # Admin routes for Team Analytics Configuration
  resources :admin_ta_teams, path: 'admin/ta_teams' do
    collection do
      get :payload
      post :validate_url
      post :assign_member
    end
    resources :admin_ta_team_memberships, path: 'memberships', as: 'memberships', only: [:create, :update, :destroy] do
      post :move, on: :member
    end
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
  end
  get 'admin/leave_count', to: 'admin_leave_count#index', as: :admin_leave_count
  post 'admin/leave_count', to: 'admin_leave_count#create'
  post 'admin/leave_count/sync_leave_inbox', to: 'admin_leave_count#sync_leave_inbox', as: :admin_leave_count_sync_leave_inbox
  get 'admin/leave_count/sync_status', to: 'admin_leave_count#sync_status', as: :admin_leave_count_sync_status
  get 'admin/leave_count/ai_models', to: 'admin_leave_count#ai_models', as: :admin_leave_count_ai_models
  get 'admin/leave_count/oauth_start', to: 'admin_leave_count#oauth_start', as: :admin_leave_count_oauth_start
  get 'admin/leave_count/oauth_callback', to: 'admin_leave_count#oauth_callback', as: :admin_leave_count_oauth_callback
  post 'webhooks/leave_email/google_apps_script', to: 'leave_webhooks#google_apps_script', as: :leave_google_apps_script_webhook
  
  resources :custom_holidays do
    collection do
      post :import_csv
    end
  end
end
