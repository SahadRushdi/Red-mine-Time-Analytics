class CreateTaExternalTimeCaches < ActiveRecord::Migration[6.1]
  def up
    return if table_exists?(:ta_external_time_caches)

    create_table :ta_external_time_caches do |t|
      t.string :entry_key, null: false, limit: 64
      t.string :project_identifier, limit: 255
      t.date :from_date, null: false
      t.date :to_date, null: false
      t.text :payload
      t.datetime :refreshed_at
      t.datetime :last_accessed_at

      t.timestamps
    end

    add_index :ta_external_time_caches, :entry_key, unique: true, name: 'idx_ta_ext_time_cache_key'
    add_index :ta_external_time_caches, :to_date
    add_index :ta_external_time_caches, :last_accessed_at
  end

  def down
    drop_table :ta_external_time_caches, if_exists: true
  end
end
