class PreserveHiringNeedHistoryOnTeamDelete < ActiveRecord::Migration[6.1]
  def up
    return unless table_exists?(:ta_hiring_needs)

    if foreign_key_exists?(:ta_hiring_needs, :ta_teams, column: :team_id)
      remove_foreign_key :ta_hiring_needs, column: :team_id
    end

    change_column_null :ta_hiring_needs, :team_id, true
    add_foreign_key :ta_hiring_needs, :ta_teams, column: :team_id, on_delete: :nullify
  end

  def down
    return unless table_exists?(:ta_hiring_needs)

    if foreign_key_exists?(:ta_hiring_needs, :ta_teams, column: :team_id)
      remove_foreign_key :ta_hiring_needs, column: :team_id
    end

    first_team_id = select_value('SELECT id FROM ta_teams ORDER BY id ASC LIMIT 1')
    if first_team_id.present?
      execute("UPDATE ta_hiring_needs SET team_id = #{first_team_id} WHERE team_id IS NULL")
    else
      execute('DELETE FROM ta_hiring_needs WHERE team_id IS NULL')
    end

    change_column_null :ta_hiring_needs, :team_id, false
    add_foreign_key :ta_hiring_needs, :ta_teams, column: :team_id, on_delete: :restrict
  end
end
