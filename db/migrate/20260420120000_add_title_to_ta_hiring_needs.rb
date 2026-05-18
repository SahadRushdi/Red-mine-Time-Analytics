class AddTitleToTaHiringNeeds < ActiveRecord::Migration[6.1]
  def up
    return unless table_exists?(:ta_hiring_needs)
    return if column_exists?(:ta_hiring_needs, :title)

    add_column :ta_hiring_needs, :title, :string, limit: 255
    execute "UPDATE ta_hiring_needs SET title = position_title WHERE title IS NULL OR title = ''"
    change_column_null :ta_hiring_needs, :title, false
  end

  def down
    return unless table_exists?(:ta_hiring_needs)
    return unless column_exists?(:ta_hiring_needs, :title)

    remove_column :ta_hiring_needs, :title
  end
end
