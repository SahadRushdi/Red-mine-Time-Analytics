class CreateTaUserTitles < ActiveRecord::Migration[6.1]
  def up
    return if table_exists?(:ta_user_titles)

    create_table :ta_user_titles do |t|
      t.integer :user_id, null: false
      t.bigint :title_id, null: false
      t.timestamps
    end

    add_index :ta_user_titles, :user_id, unique: true
    add_index :ta_user_titles, :title_id
  end

  def down
    drop_table :ta_user_titles, if_exists: true
  end
end
