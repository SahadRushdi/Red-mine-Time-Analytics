# frozen_string_literal: true

# TaTeamAccessPermission model represents fine-grained access control for team dashboards
# Allows specific users to view or manage specific teams (future enhancement)
class TaTeamAccessPermission < ActiveRecord::Base
  self.table_name = 'ta_team_access_permissions'

  # Associations
  belongs_to :team, class_name: 'TaTeam', foreign_key: 'team_id'
  belongs_to :user

  # Validations
  validates :team_id, presence: true
  validates :user_id, presence: true
  validates :user_id, uniqueness: { scope: :team_id, message: "already has permissions for this team" }

  # Scopes
  scope :can_view, -> { where(can_view: true) }
  scope :can_manage, -> { where(can_manage: true) }
  scope :for_user, ->(user_id) { where(user_id: user_id) }
  scope :for_team, ->(team_id) { where(team_id: team_id) }

  # Class Methods

  # Grant view permission to a user for a team
  # @param user_id [Integer] User ID
  # @param team_id [Integer] Team ID
  # @return [TaTeamAccessPermission] The created or updated permission
  def self.grant_view_access(user_id, team_id)
    permission = find_or_initialize_by(user_id: user_id, team_id: team_id)
    permission.can_view = true
    permission.save
    permission
  end

  # Grant manage permission to a user for a team
  # @param user_id [Integer] User ID
  # @param team_id [Integer] Team ID
  # @return [TaTeamAccessPermission] The created or updated permission
  def self.grant_manage_access(user_id, team_id)
    permission = find_or_initialize_by(user_id: user_id, team_id: team_id)
    permission.can_view = true
    permission.can_manage = true
    permission.save
    permission
  end

  # Revoke all permissions for a user on a team
  # @param user_id [Integer] User ID
  # @param team_id [Integer] Team ID
  # @return [Boolean] true if revoked
  def self.revoke_access(user_id, team_id)
    permission = find_by(user_id: user_id, team_id: team_id)
    permission&.destroy || true
  end

  # Check if user can view a specific team
  # @param user_id [Integer] User ID
  # @param team_id [Integer] Team ID
  # @return [Boolean] true if user has view permission
  def self.can_view_team?(user_id, team_id)
    exists?(user_id: user_id, team_id: team_id, can_view: true)
  end

  # Check if user can manage a specific team
  # @param user_id [Integer] User ID
  # @param team_id [Integer] Team ID
  # @return [Boolean] true if user has manage permission
  def self.can_manage_team?(user_id, team_id)
    exists?(user_id: user_id, team_id: team_id, can_manage: true)
  end

  # Get all teams a user can view
  # @param user_id [Integer] User ID
  # @return [ActiveRecord::Relation] Teams user can view
  def self.viewable_teams_for(user_id)
    TaTeam.joins(:team_access_permissions)
          .where(ta_team_access_permissions: { user_id: user_id, can_view: true })
  end

  # Get all teams a user can manage
  # @param user_id [Integer] User ID
  # @return [ActiveRecord::Relation] Teams user can manage
  def self.manageable_teams_for(user_id)
    TaTeam.joins(:team_access_permissions)
          .where(ta_team_access_permissions: { user_id: user_id, can_manage: true })
  end

  # Get all users who can view a team
  # @param team_id [Integer] Team ID
  # @return [ActiveRecord::Relation] Users with view access
  def self.users_with_view_access(team_id)
    User.joins(:ta_team_access_permissions)
        .where(ta_team_access_permissions: { team_id: team_id, can_view: true })
  end

  # Get all users who can manage a team
  # @param team_id [Integer] Team ID
  # @return [ActiveRecord::Relation] Users with manage access
  def self.users_with_manage_access(team_id)
    User.joins(:ta_team_access_permissions)
        .where(ta_team_access_permissions: { team_id: team_id, can_manage: true })
  end

  # Instance Methods

  # Grant view permission
  # @return [Boolean] true if saved
  def grant_view!
    update(can_view: true)
  end

  # Revoke view permission
  # @return [Boolean] true if saved
  def revoke_view!
    update(can_view: false)
  end

  # Grant manage permission (automatically grants view too)
  # @return [Boolean] true if saved
  def grant_manage!
    update(can_view: true, can_manage: true)
  end

  # Revoke manage permission
  # @return [Boolean] true if saved
  def revoke_manage!
    update(can_manage: false)
  end

  # Check if user has any access (view or manage)
  # @return [Boolean] true if can view or manage
  def has_any_access?
    can_view || can_manage
  end

  # Get permission level as string
  # @return [String] Permission level description
  def permission_level
    if can_manage
      'Manager'
    elsif can_view
      'Viewer'
    else
      'No Access'
    end
  end

  # Get user name (convenience method)
  # @return [String] User's name
  def user_name
    user&.name || user&.login || 'Unknown User'
  end

  # Get team name (convenience method)
  # @return [String] Team name
  def team_name
    team&.name || 'Unknown Team'
  end
end
