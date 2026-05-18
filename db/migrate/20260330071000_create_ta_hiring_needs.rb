class CreateTaHiringNeeds < ActiveRecord::Migration[6.1]
  def up
    return if table_exists?(:ta_hiring_needs)

    create_table :ta_hiring_needs do |t|
      t.string :position_title, null: false, limit: 255
      t.bigint :team_id, null: false
      t.string :role, null: false, limit: 100
      t.string :priority, null: false, limit: 20, default: 'medium'
      t.string :status, null: false, limit: 20, default: 'open'
      t.date :filled_on
      t.timestamps
    end

    add_foreign_key :ta_hiring_needs, :ta_teams, column: :team_id, on_delete: :restrict
    add_index :ta_hiring_needs, :team_id
    add_index :ta_hiring_needs, :status
    add_index :ta_hiring_needs, :priority
    add_index :ta_hiring_needs, :created_at
  end

  def down
    drop_table :ta_hiring_needs, if_exists: true
  end
end
