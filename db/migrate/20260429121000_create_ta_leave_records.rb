class CreateTaLeaveRecords < ActiveRecord::Migration[6.1]
  def up
    return if table_exists?(:ta_leave_records)

    create_table :ta_leave_records do |t|
      t.integer :user_id, null: false
      t.date :leave_date, null: false
      t.decimal :leave_fraction, precision: 4, scale: 2, null: false, default: 1.0
      t.string :status, null: false, default: 'confirmed', limit: 20
      t.string :sender_email, limit: 255
      t.string :recipient_email, limit: 255
      t.string :source_message_id, limit: 255
      t.string :source_thread_id, limit: 255
      t.datetime :source_sent_at
      t.string :raw_subject, limit: 1000
      t.text :raw_body
      t.string :sync_mode, limit: 20

      t.timestamps
    end

    add_foreign_key :ta_leave_records, :users, column: :user_id, on_delete: :cascade
    add_index :ta_leave_records, [:user_id, :leave_date], unique: true, name: 'idx_ta_leave_user_date'
    add_index :ta_leave_records, :leave_date
    add_index :ta_leave_records, :status
    add_index :ta_leave_records, :source_message_id
    add_index :ta_leave_records, :source_sent_at
  end

  def down
    drop_table :ta_leave_records, if_exists: true
  end
end
