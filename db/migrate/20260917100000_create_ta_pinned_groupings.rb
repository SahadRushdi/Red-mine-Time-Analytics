class CreateTaPinnedGroupings < ActiveRecord::Migration[6.1]
  def up
    return if table_exists?(:ta_pinned_groupings)

    create_table :ta_pinned_groupings do |t|
      t.integer :custom_field_id, null: false
      t.integer :position, null: false, default: 1

      t.timestamps
    end

    add_index :ta_pinned_groupings, :custom_field_id, unique: true, name: 'idx_ta_pinned_groupings_cf'
    add_index :ta_pinned_groupings, :position
  end

  def down
    drop_table :ta_pinned_groupings, if_exists: true
  end
end
