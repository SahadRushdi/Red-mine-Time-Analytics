class AllowNullUserForFlaggedLeaveRecords < ActiveRecord::Migration[6.1]
  def up
    return unless table_exists?(:ta_leave_records)

    change_column_null :ta_leave_records, :user_id, true
  end

  def down
    return unless table_exists?(:ta_leave_records)

    execute <<~SQL.squish
      DELETE FROM ta_leave_records
      WHERE user_id IS NULL
    SQL
    change_column_null :ta_leave_records, :user_id, false
  end
end
