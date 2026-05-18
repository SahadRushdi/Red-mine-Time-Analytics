class RemoveRoleFromTaHiringNeeds < ActiveRecord::Migration[6.1]
  def up
    return unless table_exists?(:ta_hiring_needs)
    return unless column_exists?(:ta_hiring_needs, :role)

    remove_column :ta_hiring_needs, :role, :string
  end

  def down
    return unless table_exists?(:ta_hiring_needs)
    return if column_exists?(:ta_hiring_needs, :role)

    add_column :ta_hiring_needs, :role, :string, null: false, limit: 100, default: 'Team Member'
  end
end
