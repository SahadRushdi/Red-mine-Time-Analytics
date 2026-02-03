class ConvertPersonalProjectUrlToJson < ActiveRecord::Migration[6.1]
  def up
    # Add new column for storing multiple URLs as JSON
    unless column_exists?(:ta_teams, :personal_project_urls)
      add_column :ta_teams, :personal_project_urls, :text, null: true
    end
    
    # Migrate existing single URL to JSON array format
    TaTeam.reset_column_information
    TaTeam.find_each do |team|
      if team.personal_project_url.present?
        team.update_column(:personal_project_urls, [team.personal_project_url].to_json)
      end
    end
    
    # Remove old column
    if column_exists?(:ta_teams, :personal_project_url)
      remove_column :ta_teams, :personal_project_url
    end
  end

  def down
    # Add back the old column
    unless column_exists?(:ta_teams, :personal_project_url)
      add_column :ta_teams, :personal_project_url, :text, null: true
    end
    
    # Migrate back to single URL (take first URL from array)
    TaTeam.reset_column_information
    TaTeam.find_each do |team|
      if team.personal_project_urls.present?
        urls = JSON.parse(team.personal_project_urls) rescue []
        team.update_column(:personal_project_url, urls.first) if urls.any?
      end
    end
    
    # Remove new column
    if column_exists?(:ta_teams, :personal_project_urls)
      remove_column :ta_teams, :personal_project_urls
    end
  end
end
