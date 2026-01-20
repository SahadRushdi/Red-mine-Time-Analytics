class CreateCustomHolidays < ActiveRecord::Migration[6.1]
  def change
    create_table :custom_holidays do |t|
      t.string :name, null: false
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.text :description
      t.boolean :active, default: true
      t.timestamps
    end

    add_index :custom_holidays, :start_date
    add_index :custom_holidays, :end_date
    add_index :custom_holidays, :active
  end
end
