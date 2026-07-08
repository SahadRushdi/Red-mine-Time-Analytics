class AddHideSupportTimeToTaTeams < ActiveRecord::Migration[6.1]
  def up
    unless column_exists?(:ta_teams, :hide_support_time)
      add_column :ta_teams, :hide_support_time, :boolean, null: false, default: false
    end
  end

  def down
    if column_exists?(:ta_teams, :hide_support_time)
      remove_column :ta_teams, :hide_support_time
    end
  end
end
