class CreateTaActivityGroups < ActiveRecord::Migration[6.1]
  def up
    unless table_exists?(:ta_activity_groups)
      create_table :ta_activity_groups do |t|
        t.string :name, null: false, limit: 255
        t.integer :position, null: false, default: 0
        t.timestamps
      end

      add_index :ta_activity_groups, :name, unique: true
    end

    unless table_exists?(:ta_activity_group_assignments)
      create_table :ta_activity_group_assignments do |t|
        t.integer :activity_id, null: false
        t.bigint :group_id, null: false
        t.timestamps
      end

      add_index :ta_activity_group_assignments, :activity_id, unique: true
      add_index :ta_activity_group_assignments, :group_id
    end
  end

  def down
    drop_table :ta_activity_group_assignments, if_exists: true
    drop_table :ta_activity_groups, if_exists: true
  end
end
