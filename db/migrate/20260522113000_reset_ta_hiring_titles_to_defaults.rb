class ResetTaHiringTitlesToDefaults < ActiveRecord::Migration[6.1]
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

  def up
    return unless table_exists?(:ta_hiring_titles)

    normalized_defaults = DEFAULT_TITLES.map(&:to_s).map(&:strip).reject(&:blank?).uniq

    MigrationTaHiringTitle.where.not(title: normalized_defaults).delete_all

    normalized_defaults.each do |title|
      row = MigrationTaHiringTitle.find_or_initialize_by(title: title)
      row.active = true
      row.save! if row.new_record? || !row.active?
    end
  end

  def down
    # no-op: keep curated title set
  end
end
