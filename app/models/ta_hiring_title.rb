# frozen_string_literal: true

class TaHiringTitle < ActiveRecord::Base
  self.table_name = 'ta_hiring_titles'

  # Alias so Query/TimeReport value formatting (which calls .name on the klass record) works.
  alias_attribute :name, :title

  has_many :ta_user_titles, foreign_key: 'title_id', dependent: :destroy
  has_many :users, through: :ta_user_titles

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

  validates :title, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 255 }

  scope :active_ordered, lambda {
    quoted_defaults = DEFAULT_TITLES.each_with_index.map do |title, index|
      "WHEN #{connection.quote(title)} THEN #{index + 1}"
    end.join(' ')

    where(active: true).order(
      Arel.sql("CASE title #{quoted_defaults} ELSE #{DEFAULT_TITLES.length + 1} END ASC, LOWER(title) ASC")
    )
  }
end
