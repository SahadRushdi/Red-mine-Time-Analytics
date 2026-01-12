# frozen_string_literal: true

# TaTeamProject model represents the association between a team and a Redmine project
# Includes effective date range to track when projects were assigned to teams
class TaTeamProject < ActiveRecord::Base
  self.table_name = 'ta_team_projects'

  # Associations
  belongs_to :team, class_name: 'TaTeam', foreign_key: 'team_id'
  belongs_to :project

  # Validations
  validates :team_id, presence: true
  validates :project_id, presence: true
  validates :start_date, presence: true
  validate :end_date_after_start_date
  validate :no_overlapping_project_assignments

  # Scopes
  scope :active, -> { where(end_date: nil) }
  scope :inactive, -> { where.not(end_date: nil) }
  scope :ordered_by_start_date, -> { order(start_date: :desc) }

  # Scope: Get assignments active on a specific date
  # @param date [Date] Date to check
  scope :active_on, ->(date) {
    where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', date, date)
  }

  # Scope: Get assignments active during a date range
  # @param start_date [Date] Start of range
  # @param end_date [Date] End of range
  scope :active_between, ->(start_date, end_date) {
    where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', end_date, start_date)
  }

  # Instance Methods

  # Check if assignment is currently active
  # @return [Boolean] true if end_date is nil
  def active?
    end_date.nil?
  end

  # Check if assignment was active on a specific date
  # @param date [Date] Date to check
  # @return [Boolean] true if active on that date
  def active_on?(date)
    start_date <= date && (end_date.nil? || end_date >= date)
  end

  # Get duration of assignment in days
  # @return [Integer, nil] Number of days, or nil if still active
  def duration_in_days
    return nil if end_date.nil?
    (end_date - start_date).to_i
  end

  # Get formatted date range
  # @return [String] Formatted date range
  def date_range
    if end_date.nil?
      "#{start_date.strftime('%Y-%m-%d')} to present"
    else
      "#{start_date.strftime('%Y-%m-%d')} to #{end_date.strftime('%Y-%m-%d')}"
    end
  end

  # End the assignment (set end_date to today)
  # @return [Boolean] true if saved successfully
  def end_assignment!
    update(end_date: Date.today)
  end

  # Get project name (convenience method)
  # @return [String] Project name
  def project_name
    project&.name || 'Unknown Project'
  end

  # Get team name (convenience method)
  # @return [String] Team name
  def team_name
    team&.name || 'Unknown Team'
  end

  private

  # Validation: Ensure end_date is after start_date
  def end_date_after_start_date
    return if end_date.nil? || start_date.nil?
    
    if end_date < start_date
      errors.add(:end_date, "must be after start date")
    end
  end

  # Validation: Prevent overlapping project assignments for same team-project combination
  def no_overlapping_project_assignments
    return if team_id.nil? || project_id.nil? || start_date.nil?

    # Build query to check for overlaps
    query = TaTeamProject.where(team_id: team_id, project_id: project_id)
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
      errors.add(:base, "Project is already assigned to this team during this period")
    end
  end
end
