class AddExternalSourceFieldsToTaTeamProjects < ActiveRecord::Migration[6.1]
  def up
    return unless table_exists?(:ta_team_projects)

    unless column_exists?(:ta_team_projects, :source_type)
      add_column :ta_team_projects, :source_type, :string, null: false, default: 'local', limit: 20
    end

    unless column_exists?(:ta_team_projects, :external_project_url)
      add_column :ta_team_projects, :external_project_url, :text
    end

    unless column_exists?(:ta_team_projects, :external_project_identifier)
      add_column :ta_team_projects, :external_project_identifier, :string, limit: 255
    end

    change_column_null :ta_team_projects, :project_id, true

    add_index :ta_team_projects, :source_type unless index_exists?(:ta_team_projects, :source_type)
    unless index_exists?(:ta_team_projects, [:team_id, :source_type, :project_id, :start_date, :end_date], name: 'idx_ta_team_projects_local_dates')
      add_index :ta_team_projects, [:team_id, :source_type, :project_id, :start_date, :end_date], name: 'idx_ta_team_projects_local_dates'
    end

    unless index_exists?(:ta_team_projects, [:team_id, :source_type, :external_project_identifier, :start_date, :end_date], name: 'idx_ta_team_projects_external_dates')
      add_index :ta_team_projects, [:team_id, :source_type, :external_project_identifier, :start_date, :end_date], name: 'idx_ta_team_projects_external_dates'
    end
  end

  def down
    return unless table_exists?(:ta_team_projects)

    remove_index :ta_team_projects, name: 'idx_ta_team_projects_external_dates' if index_exists?(:ta_team_projects, name: 'idx_ta_team_projects_external_dates')
    remove_index :ta_team_projects, name: 'idx_ta_team_projects_local_dates' if index_exists?(:ta_team_projects, name: 'idx_ta_team_projects_local_dates')
    remove_index :ta_team_projects, :source_type if index_exists?(:ta_team_projects, :source_type)

    remove_column :ta_team_projects, :external_project_identifier if column_exists?(:ta_team_projects, :external_project_identifier)
    remove_column :ta_team_projects, :external_project_url if column_exists?(:ta_team_projects, :external_project_url)
    remove_column :ta_team_projects, :source_type if column_exists?(:ta_team_projects, :source_type)

    change_column_null :ta_team_projects, :project_id, false
  end
end
