# frozen_string_literal: true

class TaActivityGroup < ActiveRecord::Base
  self.table_name = 'ta_activity_groups'

  UNGROUPED_NAME = 'Ungrouped'
  UNGROUPED_COLOR = '#9CA3AF'

  TABLEAU10_COLORS = [
    '#4E79A7', '#F28E2B', '#E15759', '#76B7B2', '#59A14F',
    '#EDC948', '#B07AA1', '#FF9DA7', '#9C755F', '#BAB0AC'
  ].freeze

  has_many :ta_activity_group_assignments, foreign_key: 'group_id', dependent: :destroy

  # Cycles through the shared Tableau10 palette by index, matching how activities/projects/
  # members are colored elsewhere in this plugin (TeamAnalyticsController::TABLEAU10_COLORS).
  def self.tableau10_colors(count)
    Array.new(count) { |i| TABLEAU10_COLORS[i % TABLEAU10_COLORS.size] }
  end

  before_validation :assign_next_position, on: :create

  validates :name, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 255 }
  validates :position, presence: true
  validate :name_is_not_reserved

  scope :ordered, -> { order(:position, :id) }

  private

  # Always assigns the next position on create — the DB column has a `default: 0`, which is
  # truthy in Ruby, so a `self.position ||= ...` guard would never fire and every new group
  # would silently stay at position 0. Nothing in this app ever needs to set a custom position
  # on create (reordering is a separate bulk update_all in AdminTaActivityGroupsController#reorder).
  def assign_next_position
    self.position = TaActivityGroup.maximum(:position).to_i + 1
  end

  def name_is_not_reserved
    return if name.blank?

    errors.add(:name, :invalid) if name.strip.casecmp(UNGROUPED_NAME).zero?
  end
end
