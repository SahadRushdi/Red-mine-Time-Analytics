# frozen_string_literal: true

class TaHiringTitle < ActiveRecord::Base
  self.table_name = 'ta_hiring_titles'

  validates :title, presence: true, length: { maximum: 255 }, uniqueness: { case_sensitive: false }

  scope :active, -> { where(active: true) }
  scope :ordered_by_title, -> { order(Arel.sql('LOWER(title) ASC')) }

  before_validation :normalize_title

  private

  def normalize_title
    self.title = title.to_s.strip
  end
end
