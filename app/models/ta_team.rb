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
  has_many :ta_hiring_needs, class_name: 'TaHiringNeed', foreign_key: 'team_id', dependent: :restrict_with_error

  alias_method :children, :child_teams
  alias_method :team_memberships, :ta_team_memberships
  alias_method :team_projects, :ta_team_projects

  # Validations
  validates :name, presence: true, uniqueness: true, length: { maximum: 255 }
  validate :cannot_be_own_parent
  validate :cannot_create_circular_hierarchy
  validate :validate_personal_project_urls

  # Safe attributes for mass assignment
  safe_attributes 'name', 'parent_team_id', 'description', 'personal_project_urls'
  
  # Serialize personal_project_urls as JSON array
  serialize :personal_project_urls, JSON

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

  # Get all hierarchical members (own + inherited from child teams) for a date range
  # Members bubble up from child teams to parents
  # @param start_date [Date] Start of date range
  # @param end_date [Date] End of date range
  # @return [Array<TaTeamMembership>] Unique memberships including inherited ones
  def hierarchical_members(start_date, end_date)
    member_hash = {}
    
    # Get own direct members
    own_members = active_members(start_date, end_date).to_a
    own_members.each do |membership|
      key = "#{membership.user_id}_#{membership.team_id}"
      member_hash[key] = membership
    end
    
    # Get members from all child teams (bubble up)
    all_descendants.each do |child_team|
      child_members = child_team.active_members(start_date, end_date).to_a
      child_members.each do |membership|
        key = "#{membership.user_id}_#{membership.team_id}"
        # Add only if not already present (avoid duplicates)
        member_hash[key] ||= membership
      end
    end
    
    member_hash.values
  end

  # Get current hierarchical members (including inherited from child teams)
  # @return [Array<TaTeamMembership>] Unique memberships including inherited ones
  def current_hierarchical_members
    member_hash = {}
    
    # Get own direct members
    own_members = current_members.to_a
    own_members.each do |membership|
      key = "#{membership.user_id}_#{membership.team_id}"
      member_hash[key] = membership
    end
    
    # Get members from all child teams (bubble up)
    all_descendants.each do |child_team|
      child_members = child_team.current_members.to_a
      child_members.each do |membership|
        key = "#{membership.user_id}_#{membership.team_id}"
        member_hash[key] ||= membership
      end
    end
    
    member_hash.values
  end

  # Get unique user IDs for hierarchical members (for analytics queries)
  # @param start_date [Date] Start of date range
  # @param end_date [Date] End of date range
  # @return [Array<Integer>] Unique user IDs
  def hierarchical_member_ids(start_date, end_date)
    hierarchical_members(start_date, end_date).map(&:user_id).uniq
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

  # Get all personal project URLs including inherited from parent teams
  # @return [Array<String>] Array of project URLs
  def all_personal_project_urls
    urls = []
    
    # Add own URLs
    own_urls = parse_personal_project_urls
    urls.concat(own_urls) if own_urls.any?
    
    # Add parent team URLs (hierarchical inheritance)
    current_parent = parent_team
    while current_parent
      parent_urls = current_parent.parse_personal_project_urls
      urls.concat(parent_urls) if parent_urls.any?
      current_parent = current_parent.parent_team
    end
    
    urls.uniq
  end
  
  # Parse personal_project_urls from JSON
  # @return [Array<String>] Array of URLs
  def parse_personal_project_urls
    return [] if personal_project_urls.blank?
    
    if personal_project_urls.is_a?(String)
      begin
        JSON.parse(personal_project_urls)
      rescue JSON::ParserError
        []
      end
    elsif personal_project_urls.is_a?(Array)
      personal_project_urls
    else
      []
    end
  end

  # Get all personal project parents from URLs (including inherited)
  # @return [Array<Project>] Array of parent projects
  def personal_project_parents
    urls = all_personal_project_urls
    return [] if urls.empty?
    
    urls.map do |url|
      identifier = extract_project_identifier(url)
      next if identifier.nil?
      Project.find_by(identifier: identifier, status: Project::STATUS_ACTIVE)
    end.compact
  end

  # Get all personal project IDs (all parents + all descendants, including inherited)
  # @return [Array<Integer>] Array of project IDs
  def personal_project_ids
    parents = personal_project_parents
    return [] if parents.empty?
    
    project_ids = []
    parents.each do |parent|
      project_ids.concat(parent.self_and_descendants.pluck(:id))
    end
    
    project_ids.uniq
  end

  # Check if a project is a personal project
  # @param project_id [Integer] Project ID to check
  # @return [Boolean] true if project is personal
  def personal_project?(project_id)
    personal_project_ids.include?(project_id)
  end

  # Extract project identifier from URL
  # @param url [String] Project URL
  # @return [String, nil] Project identifier or nil
  def extract_project_identifier(url)
    return nil if url.blank?
    
    match = url.match(/\/projects\/([a-z0-9\-_]+)/i)
    match ? match[1] : nil
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

  # Validation: Validate personal project URLs
  def validate_personal_project_urls
    return if personal_project_urls.blank?
    
    urls = parse_personal_project_urls
    return if urls.empty?
    
    urls.each_with_index do |url, index|
      next if url.blank?
      
      identifier = extract_project_identifier(url)
      if identifier.nil?
        errors.add(:personal_project_urls, "URL #{index + 1}: invalid format. Expected format: http://host/projects/project-identifier")
        next
      end
      
      project = Project.find_by(identifier: identifier)
      if project.nil?
        errors.add(:personal_project_urls, "URL #{index + 1}: project not found or inactive")
      end
    end
  end
end
