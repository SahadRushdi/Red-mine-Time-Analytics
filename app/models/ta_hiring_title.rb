# frozen_string_literal: true

class TaHiringTitle < ActiveRecord::Base
  self.table_name = 'ta_hiring_titles'

  validates :title, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 255 }

  scope :active_ordered, -> { where(active: true).order(Arel.sql('LOWER(title) ASC')) }
end
