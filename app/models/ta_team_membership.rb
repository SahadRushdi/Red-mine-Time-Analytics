# frozen_string_literal: true

# TaTeamMembership model represents a user's membership in a team
# Includes role (lead/member) and effective date range for historical tracking
class TaTeamMembership < ActiveRecord::Base
  self.table_name = 'ta_team_memberships'

  # Constants
  ROLES = %w[lead member].freeze

  # Associations
  belongs_to :team, class_name: 'TaTeam', foreign_key: 'team_id'
  belongs_to :user

  # Validations
  validates :team_id, presence: true
  validates :user_id, presence: true
  validates :role, presence: true, inclusion: { in: ROLES, message: "%{value} is not a valid role" }
  validates :start_date, presence: true
  validate :end_date_after_start_date
  validate :no_overlapping_memberships

  # Scopes
  scope :active, -> { where(end_date: nil) }
  scope :inactive, -> { where.not(end_date: nil) }
  scope :leads, -> { where(role: 'lead') }
  scope :members, -> { where(role: 'member') }
  scope :ordered_by_start_date, -> { order(start_date: :desc) }

  # Scope: Get memberships active on a specific date
  # @param date [Date] Date to check
  scope :active_on, ->(date) {
    where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', date, date)
  }

  # Scope: Get memberships active during a date range
  # @param start_date [Date] Start of range
  # @param end_date [Date] End of range
  scope :active_between, ->(start_date, end_date) {
    where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', end_date, start_date)
  }

  # Instance Methods

  # Check if membership is currently active
  # @return [Boolean] true if end_date is nil
  def active?
    end_date.nil?
  end

  # Check if user is a team lead
  # @return [Boolean] true if role is 'lead'
  def lead?
    role == 'lead'
  end

  # Check if user is a team member
  # @return [Boolean] true if role is 'member'
  def member?
    role == 'member'
  end

  # Check if membership was active on a specific date
  # @param date [Date] Date to check
  # @return [Boolean] true if active on that date
  def active_on?(date)
    start_date <= date && (end_date.nil? || end_date >= date)
  end

  # Get duration of membership in days
  # @return [Integer, nil] Number of days, or nil if still active
  def duration_in_days
    return nil if end_date.nil?
    (end_date - start_date).to_i
  end

  # Get formatted date range
  # @return [String] Formatted date range (e.g., "2024-01-01 to 2024-12-31" or "2024-01-01 to present")
  def date_range
    if end_date.nil?
      "#{start_date.strftime('%Y-%m-%d')} to present"
    else
      "#{start_date.strftime('%Y-%m-%d')} to #{end_date.strftime('%Y-%m-%d')}"
    end
  end

  # End the membership (set end_date to today)
  # @return [Boolean] true if saved successfully
  def end_membership!
    update(end_date: Date.today)
  end

  private

  # Validation: Ensure end_date is after start_date
  def end_date_after_start_date
    return if end_date.nil? || start_date.nil?
    
    if end_date < start_date
      errors.add(:end_date, "must be after start date")
    end
  end

  # Validation: Prevent overlapping memberships for same user in same team
  def no_overlapping_memberships
    return if user_id.nil? || team_id.nil? || start_date.nil?

    # Build query to check for overlaps
    query = TaTeamMembership.where(team_id: team_id, user_id: user_id)
    query = query.where.not(id: id) if persisted?

    # Check for overlapping date ranges
    overlapping = query.where(
      '(start_date <= ? AND (end_date IS NULL OR end_date >= ?)) OR (? <= start_date AND (? IS NULL OR ? >= start_date))',
      end_date || Date.new(9999, 12, 31), # Use far future date if end_date is nil
      start_date,
      start_date,
      end_date,
      end_date
    )

    if overlapping.exists?
      errors.add(:base, "User already has an overlapping membership in this team during this period")
    end
  end
end
