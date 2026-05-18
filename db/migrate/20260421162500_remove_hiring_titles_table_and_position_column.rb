class RemoveHiringTitlesTableAndPositionColumn < ActiveRecord::Migration[6.1]
  def up
    return unless table_exists?(:ta_hiring_needs)

    if column_exists?(:ta_hiring_needs, :position_title)
      if column_exists?(:ta_hiring_needs, :title)
        execute <<~SQL.squish
          UPDATE ta_hiring_needs
          SET title = position_title
          WHERE (title IS NULL OR title = '') AND position_title IS NOT NULL AND position_title != ''
        SQL
      end
      remove_column :ta_hiring_needs, :position_title
    end

    drop_table :ta_hiring_titles, if_exists: true
  end

  def down
    return unless table_exists?(:ta_hiring_needs)

    unless table_exists?(:ta_hiring_titles)
      create_table :ta_hiring_titles do |t|
        t.string :title, null: false, limit: 255
        t.boolean :active, null: false, default: true
        t.timestamps
      end
      add_index :ta_hiring_titles, :title, unique: true
      add_index :ta_hiring_titles, :active
    end

    return if column_exists?(:ta_hiring_needs, :position_title)

    add_column :ta_hiring_needs, :position_title, :string, null: false, limit: 255, default: ''
    execute "UPDATE ta_hiring_needs SET position_title = title WHERE title IS NOT NULL"
    change_column_default :ta_hiring_needs, :position_title, nil
  end
end
