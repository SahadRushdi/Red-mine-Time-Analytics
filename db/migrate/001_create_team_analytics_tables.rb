class CreateTeamAnalyticsTables < ActiveRecord::Migration[6.1]
  def up
    # Table 1: Teams (hierarchical structure)
    unless table_exists?(:ta_teams)
      create_table :ta_teams do |t|
        t.string :name, null: false, limit: 255
        t.bigint :parent_team_id, null: true
        t.text :description

        t.timestamps
      end

      add_index :ta_teams, :name, unique: true
      add_index :ta_teams, :parent_team_id
      add_foreign_key :ta_teams, :ta_teams, column: :parent_team_id, on_delete: :restrict
    end

    # Table 2: Team Memberships
    unless table_exists?(:ta_team_memberships)
      create_table :ta_team_memberships do |t|
        t.bigint :team_id, null: false
        t.integer :user_id, null: false
        t.string :role, null: false, limit: 20
        t.date :start_date, null: false
        t.date :end_date, null: true

        t.timestamps
      end

      add_foreign_key :ta_team_memberships, :ta_teams, column: :team_id, on_delete: :cascade
      add_foreign_key :ta_team_memberships, :users, column: :user_id, on_delete: :cascade
      
      add_index :ta_team_memberships, :team_id
      add_index :ta_team_memberships, :user_id
      add_index :ta_team_memberships, [:team_id, :user_id, :start_date, :end_date], 
                name: 'idx_ta_team_memberships_dates'
      add_index :ta_team_memberships, :role
      add_index :ta_team_memberships, :end_date
    end

    # Table 3: Team Projects
    unless table_exists?(:ta_team_projects)
      create_table :ta_team_projects do |t|
        t.bigint :team_id, null: false
        t.integer :project_id, null: false
        t.date :start_date, null: false
        t.date :end_date, null: true

        t.timestamps
      end

      add_foreign_key :ta_team_projects, :ta_teams, column: :team_id, on_delete: :cascade
      add_foreign_key :ta_team_projects, :projects, column: :project_id, on_delete: :cascade
      
      add_index :ta_team_projects, :team_id
      add_index :ta_team_projects, :project_id
      add_index :ta_team_projects, [:team_id, :project_id, :start_date, :end_date],
                name: 'idx_ta_team_projects_dates'
      add_index :ta_team_projects, :end_date
    end

    # Table 4: Team Settings
    unless table_exists?(:ta_team_settings)
      create_table :ta_team_settings do |t|
        t.string :setting_type, null: false, limit: 50
        t.integer :user_id, null: false
        t.boolean :active, null: false, default: true
        t.text :notes

        t.timestamps
      end

      add_foreign_key :ta_team_settings, :users, column: :user_id, on_delete: :cascade
      
      add_index :ta_team_settings, :user_id
      add_index :ta_team_settings, [:user_id, :setting_type], unique: true
      add_index :ta_team_settings, :setting_type
      add_index :ta_team_settings, :active
    end

    # Table 5: Team Access Permissions
    unless table_exists?(:ta_team_access_permissions)
      create_table :ta_team_access_permissions do |t|
        t.bigint :team_id, null: false
        t.integer :user_id, null: false
        t.boolean :can_view, null: false, default: true
        t.boolean :can_manage, null: false, default: false

        t.timestamps
      end

      add_foreign_key :ta_team_access_permissions, :ta_teams, column: :team_id, on_delete: :cascade
      add_foreign_key :ta_team_access_permissions, :users, column: :user_id, on_delete: :cascade
      
      add_index :ta_team_access_permissions, :team_id
      add_index :ta_team_access_permissions, :user_id
      add_index :ta_team_access_permissions, [:team_id, :user_id], unique: true
    end
  end

  def down
    drop_table :ta_team_access_permissions, if_exists: true
    drop_table :ta_team_settings, if_exists: true
    drop_table :ta_team_projects, if_exists: true
    drop_table :ta_team_memberships, if_exists: true
    drop_table :ta_teams, if_exists: true
  end
end
