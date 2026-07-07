# frozen_string_literal: true

# Associates a Redmine TimeEntryActivity (Enumeration) with one TaActivityGroup.
# Current-only: an activity has at most one group (enforced by the unique activity_id index/validation).
# Activities with no row here fall back to the computed "Ungrouped" bucket at read time.
class TaActivityGroupAssignment < ActiveRecord::Base
  self.table_name = 'ta_activity_group_assignments'

  belongs_to :group, class_name: 'TaActivityGroup', foreign_key: 'group_id'

  validates :activity_id, presence: true, uniqueness: true
  validates :group_id, presence: true
end
