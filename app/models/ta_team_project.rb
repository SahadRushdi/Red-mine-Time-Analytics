# frozen_string_literal: true

# TaTeamProject model represents the association between a team and a Redmine project
# Includes effective date range to track when projects were assigned to teams
class TaTeamProject < ActiveRecord::Base
  self.table_name = 'ta_team_projects'

  SOURCE_TYPES = %w[local external].freeze

  # Associations
  belongs_to :team, class_name: 'TaTeam', foreign_key: 'team_id'
  belongs_to :project, optional: true

  # Validations
  validates :team_id, presence: true
  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validates :start_date, presence: true
  validates :project_id, presence: true, if: :local_source?
  validates :external_project_url, presence: true, if: :external_source?
  validate :external_project_url_format, if: :external_source?
  validate :source_specific_payload
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
    return project&.name || 'Unknown Project' if local_source?
    "External: #{external_project_identifier.presence || 'Unknown Project'}"
  end

  # Get team name (convenience method)
  # @return [String] Team name
  def team_name
    team&.name || 'Unknown Team'
  end

  def local_source?
    source_type != 'external'
  end

  def external_source?
    source_type == 'external'
  end

  def project_display_identifier
    return project&.identifier.to_s if local_source?
    external_project_identifier.to_s
  end

  def project_linkable?
    local_source? && project.present?
  end

  # Check if this is an inherited project
  # @return [Boolean] true if project is inherited from a child team
  def inherited?
    defined?(@inherited) && @inherited
  end

  # Mark this project as inherited and store the source team
  # @param source_team [TaTeam] The team this project came from
  def mark_as_inherited(source_team)
    @inherited = true
    @inherited_from_team = source_team
    @inherited_from_team_id = source_team.id
  end

  # Get the team this project was inherited from
  # @return [TaTeam, nil] The source team
  def inherited_from_team
    @inherited_from_team
  end

  # Get the ID of the team this project was inherited from
  # @return [Integer, nil] The source team ID
  def inherited_from_team_id
    @inherited_from_team_id
  end

  private

  before_validation :normalize_source_fields

  # Validation: Ensure end_date is after start_date
  def end_date_after_start_date
    return if end_date.nil? || start_date.nil?
    
    if end_date < start_date
      errors.add(:end_date, "must be after start date")
    end
  end

  # Validation: Prevent overlapping project assignments for same team-project combination
  def no_overlapping_project_assignments
    return if team_id.nil? || start_date.nil?

    # Build query to check for overlaps
    query = TaTeamProject.where(team_id: team_id, source_type: source_type.presence || 'local')
    if external_source?
      return if external_project_identifier.blank?
      query = query.where(external_project_identifier: external_project_identifier)
    else
      return if project_id.nil?
      query = query.where(project_id: project_id)
    end

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

  def normalize_source_fields
    self.source_type = source_type.presence || 'local'
    if external_source?
      self.project_id = nil
      self.external_project_url = external_project_url.to_s.strip
      self.external_project_identifier = extract_project_identifier(external_project_url)
    else
      self.external_project_url = nil
      self.external_project_identifier = nil
    end
  end

  def source_specific_payload
    if local_source? && external_project_url.present?
      errors.add(:external_project_url, 'must be blank for local projects')
    end

    if external_source? && project_id.present?
      errors.add(:project_id, 'must be blank for external projects')
    end
  end

  def external_project_url_format
    return if external_project_url.blank?
    identifier = extract_project_identifier(external_project_url)
    if identifier.blank?
      errors.add(:external_project_url, 'must include /projects/<project-identifier>')
    end
  end

  def extract_project_identifier(url)
    return nil if url.blank?
    match = url.to_s.match(%r{/projects/([a-z0-9\-_]+)}i)
    match ? match[1].downcase : nil
  end
end
