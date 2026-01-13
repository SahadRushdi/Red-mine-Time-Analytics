# frozen_string_literal: true

# TaTeam model represents a team/department in the organizational hierarchy
# Teams can have parent-child relationships (e.g., Organization → Department → Team)
class TaTeam < ActiveRecord::Base
  include Redmine::SafeAttributes
  
  self.table_name = 'ta_teams'

  # Associations
  belongs_to :parent_team, class_name: 'TaTeam', optional: true
  has_many :child_teams, class_name: 'TaTeam', foreign_key: 'parent_team_id', dependent: :restrict_with_error
  has_many :ta_team_memberships, class_name: 'TaTeamMembership', foreign_key: 'team_id', dependent: :destroy
  has_many :users, through: :ta_team_memberships
  has_many :ta_team_projects, class_name: 'TaTeamProject', foreign_key: 'team_id', dependent: :destroy
  has_many :projects, through: :ta_team_projects
  has_many :ta_team_access_permissions, class_name: 'TaTeamAccessPermission', foreign_key: 'team_id', dependent: :destroy

  alias_method :children, :child_teams
  alias_method :team_memberships, :ta_team_memberships
  alias_method :team_projects, :ta_team_projects

  # Validations
  validates :name, presence: true, uniqueness: true, length: { maximum: 255 }
  validate :cannot_be_own_parent
  validate :cannot_create_circular_hierarchy

  # Safe attributes for mass assignment
  safe_attributes 'name', 'parent_team_id', 'description'

  # Scopes
  scope :root_teams, -> { where(parent_team_id: nil) }
  scope :ordered_by_name, -> { order(:name) }

  # Instance Methods

  # Get all active members for a specific date range
  # @param start_date [Date] Start of date range
  # @param end_date [Date] End of date range
  # @return [ActiveRecord::Relation] Team memberships active during the period
  def active_members(start_date, end_date)
    team_memberships.where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', end_date, start_date)
                    .includes(:user)
  end

  # Get current active members (end_date is NULL)
  # @return [ActiveRecord::Relation] Currently active team memberships
  def current_members
    team_memberships.where(end_date: nil).includes(:user)
  end

  # Get team leads for a specific date
  # @param date [Date] Date to check (defaults to today)
  # @return [ActiveRecord::Relation] Team leads active on the given date
  def leads(date = Date.today)
    team_memberships.where(role: 'lead')
                    .where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', date, date)
                    .includes(:user)
  end

  # Get current team lead
  # @return [TaTeamMembership, nil] Current team lead or nil if none
  def current_lead
    leads.first
  end

  # Get all descendant teams recursively
  # @return [Array<TaTeam>] All child teams and their children
  def all_descendants
    descendants = []
    child_teams.each do |child|
      descendants << child
      descendants.concat(child.all_descendants)
    end
    descendants
  end

  # Get all ancestor teams recursively
  # @return [Array<TaTeam>] All parent teams up to root
  def all_ancestors
    ancestors = []
    current = parent_team
    while current
      ancestors << current
      current = current.parent_team
    end
    ancestors
  end

  # Check if this team is a root team (no parent)
  # @return [Boolean] true if root team
  def root?
    parent_team_id.nil?
  end

  # Check if this team has any child teams
  # @return [Boolean] true if has children
  def has_children?
    child_teams.any?
  end

  # Get the full hierarchical path (e.g., "Entgra > IoT > UBS")
  # @return [String] Full team path
  def full_path
    path = all_ancestors.reverse.map(&:name)
    path << name
    path.join(' > ')
  end

  # Get active projects for a date range
  # @param start_date [Date] Start of date range
  # @param end_date [Date] End of date range
  # @return [ActiveRecord::Relation] Active team projects
  def active_projects(start_date, end_date)
    team_projects.where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', end_date, start_date)
                 .includes(:project)
  end

  # Get current active projects
  # @return [ActiveRecord::Relation] Currently active projects
  def current_projects
    team_projects.where(end_date: nil).includes(:project)
  end

  private

  # Validation: Prevent team from being its own parent
  def cannot_be_own_parent
    if parent_team_id.present? && parent_team_id == id
      errors.add(:parent_team_id, "cannot be the team itself")
    end
  end

  # Validation: Prevent circular hierarchy (A -> B -> C -> A)
  def cannot_create_circular_hierarchy
    return if parent_team_id.nil? || id.nil?
    
    current = TaTeam.find_by(id: parent_team_id)
    visited = Set.new([id])
    
    while current
      if visited.include?(current.id)
        errors.add(:parent_team_id, "would create a circular hierarchy")
        break
      end
      visited.add(current.id)
      current = current.parent_team
    end
  end
end
