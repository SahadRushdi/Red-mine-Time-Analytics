class CreateTaHiringTitles < ActiveRecord::Migration[6.1]
  DEFAULT_TITLES = [
    'Intern - Dev',
    'Intern - QA',
    'Intern - BA',
    'Associate Software Engineer',
    'Software Engineer',
    'Senior Software Engineer',
    'Associate Quality Assurance Engineer',
    'Quality Assurance Engineer'
  ].freeze

  class MigrationTaHiringTitle < ActiveRecord::Base
    self.table_name = 'ta_hiring_titles'
  end

  class MigrationTaHiringNeed < ActiveRecord::Base
    self.table_name = 'ta_hiring_needs'
  end

  def up
    unless table_exists?(:ta_hiring_titles)
      create_table :ta_hiring_titles do |t|
        t.string :title, null: false, limit: 255
        t.boolean :active, null: false, default: true
        t.timestamps
      end

      add_index :ta_hiring_titles, :title, unique: true
      add_index :ta_hiring_titles, :active
    end

    seed_titles!
  end

  def down
    drop_table :ta_hiring_titles, if_exists: true
  end

  private

  def seed_titles!
    existing_titles = MigrationTaHiringTitle.pluck(:title)

    derived_titles = if table_exists?(:ta_hiring_needs)
      MigrationTaHiringNeed.where.not(title: [nil, '']).distinct.pluck(:title)
    else
      []
    end

    (DEFAULT_TITLES + derived_titles).map(&:to_s).map(&:strip).reject(&:blank?).uniq.each do |title|
      next if existing_titles.include?(title)

      MigrationTaHiringTitle.create!(title: title, active: true)
    end
  end
end
