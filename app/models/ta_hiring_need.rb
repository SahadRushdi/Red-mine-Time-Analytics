# frozen_string_literal: true

class TaHiringNeed < ActiveRecord::Base
  self.table_name = 'ta_hiring_needs'

  PRIORITIES = %w[high medium low].freeze
  STATUSES = %w[open filled].freeze

  belongs_to :team, class_name: 'TaTeam', foreign_key: 'team_id', optional: true

  validates :position_title, presence: true, length: { maximum: 255 }
  validates :team_id, presence: true, on: :create
  validates :priority, presence: true, inclusion: { in: PRIORITIES }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :open, -> { where(status: 'open') }
  scope :filled, -> { where(status: 'filled') }
  scope :ordered_by_recent, -> { order(created_at: :desc) }
  scope :ordered_priority, lambda {
    order(
      Arel.sql("CASE priority WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END"),
      created_at: :desc
    )
  }

  def filled?
    status == 'filled'
  end

  def open?
    status == 'open'
  end

  def mark_filled!(date = Date.today)
    update!(status: 'filled', filled_on: date)
  end
end
