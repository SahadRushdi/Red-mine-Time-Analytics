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

  # Re-buckets an already-computed activity pivot (see TeamAnalyticsController/TimeAnalyticsController
  # generate_activity_pivot_table) by Activity Group instead of raw activity, without re-scanning the
  # underlying time entries. Activities with no assignment fall back to the computed 'Ungrouped' bucket.
  # Returns the same hash shape so it plugs directly into generate_activity_pivot_chart_data. Shared by
  # both the Team Dashboard and Individual Dashboard's Activity "Grouped" tab.
  def self.regroup_activity_pivot(pivot_data, activity_id_to_group_name, group_names_in_order)
    matrix_data = {}
    pivot_data[:raw_periods].each { |period| matrix_data[period] = Hash.new(0.0) }

    pivot_data[:matrix].each do |period, by_activity|
      by_activity.each do |activity_name, hours|
        activity_id = pivot_data[:activity_ids][activity_name]
        group_name = activity_id && activity_id_to_group_name[activity_id]
        bucket = group_name || UNGROUPED_NAME
        matrix_data[period][bucket] += hours
      end
    end

    activities = group_names_in_order.dup
    ungrouped_total = pivot_data[:raw_periods].sum { |period| matrix_data[period][UNGROUPED_NAME] || 0 }
    # Only shown when it actually has hours in it — an empty Ungrouped column (e.g. every activity
    # has been assigned to a group) is just noise.
    activities << UNGROUPED_NAME if ungrouped_total > 0

    activity_totals = {}
    activities.each do |group_name|
      activity_totals[group_name] = pivot_data[:raw_periods].sum { |period| matrix_data[period][group_name] || 0 }
    end

    {
      periods: pivot_data[:periods],
      activities: activities,
      matrix: matrix_data,
      period_totals: pivot_data[:period_totals],
      activity_totals: activity_totals,
      grand_total: pivot_data[:grand_total],
      raw_periods: pivot_data[:raw_periods]
    }
  end

  # Builds every ivar the Activity "Grouped" tab + "Customize groups" popup need, from an
  # already-computed activity pivot. Shared by TeamAnalyticsController and TimeAnalyticsController
  # so the Grouped-tab wiring only needs to be written once.
  def self.grouped_activity_view_data(activity_pivot_data)
    all_activities = TimeEntryActivity.shared.sorted.to_a
    groups = TaActivityGroup.ordered.to_a
    assignments = TaActivityGroupAssignment.pluck(:activity_id, :group_id).to_h
    group_names_by_id = groups.index_by(&:id).transform_values(&:name)
    activity_id_to_group_name = assignments.transform_values { |gid| group_names_by_id[gid] }

    {
      all_activities: all_activities,
      groups: groups,
      assignments: assignments,
      pivot_data: regroup_activity_pivot(activity_pivot_data, activity_id_to_group_name, groups.map(&:name)),
      colors: tableau10_colors(groups.size)
    }
  end

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
