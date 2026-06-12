class AddIndexToTaLeaveRecordsDateStatus < ActiveRecord::Migration[6.1]
  def up
    unless index_exists?(:ta_leave_records, %i[leave_date status], name: 'idx_ta_leave_date_status')
      add_index :ta_leave_records, %i[leave_date status], name: 'idx_ta_leave_date_status'
    end
  end

  def down
    if index_exists?(:ta_leave_records, %i[leave_date status], name: 'idx_ta_leave_date_status')
      remove_index :ta_leave_records, name: 'idx_ta_leave_date_status'
    end
  end
end
