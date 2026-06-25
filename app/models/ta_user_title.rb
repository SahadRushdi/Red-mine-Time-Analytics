# frozen_string_literal: true

# Associates a Redmine user with one job title (TaHiringTitle).
# Current-only: a user has at most one title (enforced by the unique user_id index/validation).
class TaUserTitle < ActiveRecord::Base
  self.table_name = 'ta_user_titles'

  belongs_to :user
  belongs_to :title, class_name: 'TaHiringTitle', foreign_key: 'title_id'

  validates :user_id, presence: true, uniqueness: true
  validates :title_id, presence: true
end
