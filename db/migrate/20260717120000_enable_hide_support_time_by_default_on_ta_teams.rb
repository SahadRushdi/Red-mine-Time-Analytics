class EnableHideSupportTimeByDefaultOnTaTeams < ActiveRecord::Migration[6.1]
  class MigrationTaTeam < ActiveRecord::Base
    self.table_name = 'ta_teams'
  end

  def up
    return unless column_exists?(:ta_teams, :hide_support_time)

    # New teams pick this up automatically via the column default (TaTeam.new reads it).
    change_column_default :ta_teams, :hide_support_time, from: false, to: true
    MigrationTaTeam.reset_column_information

    # Every existing team was created under the old `false` default, so bring them in line -
    # without this the change would only apply to teams created from now on. update_all skips
    # callbacks/validations (none are relevant here) and quotes the boolean per adapter.
    MigrationTaTeam.where(hide_support_time: false).update_all(hide_support_time: true)
  end

  def down
    return unless column_exists?(:ta_teams, :hide_support_time)

    # Only the default is reverted: which teams an admin had chosen to hide before this
    # migration ran is no longer recoverable, so the backfill is intentionally not undone.
    change_column_default :ta_teams, :hide_support_time, from: true, to: false
  end
end
