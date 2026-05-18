class AddPersonalProjectUrlToTaTeams < ActiveRecord::Migration[6.1]
  def up
    unless column_exists?(:ta_teams, :personal_project_url)
      add_column :ta_teams, :personal_project_url, :text, null: true
    end
  end

  def down
    if column_exists?(:ta_teams, :personal_project_url)
      remove_column :ta_teams, :personal_project_url
    end
  end
end
