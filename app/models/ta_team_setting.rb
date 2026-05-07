# frozen_string_literal: true

# TaTeamSetting model represents plugin settings for users
# Used for exclusion list (users whose time logs are ignored) and super users (can view all teams)
class TaTeamSetting < ActiveRecord::Base
  self.table_name = 'ta_team_settings'

  # Constants
  SETTING_TYPES = %w[exclusion super_user].freeze

  # Associations
  belongs_to :user

  # Validations
  validates :user_id, presence: true
  validates :setting_type, presence: true, inclusion: { in: SETTING_TYPES, message: "%{value} is not a valid setting type" }
  validates :user_id, uniqueness: { scope: :setting_type, message: "already has this setting type" }
  validates :start_date, presence: true, if: :exclusion?
  validate :end_date_after_start_date, if: :exclusion?
  before_validation :default_exclusion_start_date, if: :exclusion?

  # Scopes
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :exclusions, -> { where(setting_type: 'exclusion', active: true) }
  scope :super_users, -> { where(setting_type: 'super_user', active: true) }
  scope :exclusions_active_on, ->(date) {
    exclusions.where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', date, date)
  }
  scope :exclusions_overlapping, ->(from_date, to_date) {
    exclusions.where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', to_date, from_date)
  }

  # Class Methods

  # Get array of user IDs that should be excluded from analytics
  # @return [Array<Integer>] User IDs in exclusion list
  def self.excluded_user_ids
    exclusions.pluck(:user_id)
  end

  # Get array of user IDs excluded during a given period
  # @param from_date [Date]
  # @param to_date [Date]
  # @return [Array<Integer>]
  def self.excluded_user_ids_for_range(from_date, to_date)
    exclusions_overlapping(from_date, to_date).distinct.pluck(:user_id)
  end

  # SQL fragment that excludes a time entry row when its spent_on date falls in an exclusion window.
  # @param entry_table_alias [String]
  # @return [String]
  def self.exclusion_time_entry_condition(entry_table_alias = 'time_entries')
    <<~SQL.squish
      NOT EXISTS (
        SELECT 1
        FROM ta_team_settings
        WHERE ta_team_settings.setting_type = 'exclusion'
          AND ta_team_settings.active = 1
          AND ta_team_settings.user_id = #{entry_table_alias}.user_id
          AND ta_team_settings.start_date <= #{entry_table_alias}.spent_on
          AND (ta_team_settings.end_date IS NULL OR ta_team_settings.end_date >= #{entry_table_alias}.spent_on)
      )
    SQL
  end

  # Get array of user IDs that are super users (can view all teams)
  # @return [Array<Integer>] Super user IDs
  def self.super_user_ids
    super_users.pluck(:user_id)
  end

  # Check if a user is excluded from analytics
  # @param user_id [Integer] User ID to check
  # @return [Boolean] true if user is in exclusion list
  def self.user_excluded?(user_id)
    excluded_user_ids.include?(user_id)
  end

  # Check if a user is a super user
  # @param user_id [Integer] User ID to check
  # @return [Boolean] true if user is a super user
  def self.user_super?(user_id)
    super_user_ids.include?(user_id)
  end

  # Add a user to exclusion list
  # @param user_id [Integer] User ID to exclude
  # @param notes [String] Optional notes about why user is excluded
  # @return [TaTeamSetting] The created or updated setting
  def self.add_to_exclusion_list(user_id, start_date: Date.current, end_date: nil, notes: nil)
    setting = find_or_initialize_by(user_id: user_id, setting_type: 'exclusion')
    setting.active = true
    setting.start_date = start_date
    setting.end_date = end_date
    setting.notes = notes if notes
    setting.save
    setting
  end

  # Remove a user from exclusion list
  # @param user_id [Integer] User ID to remove
  # @return [Boolean] true if removed successfully
  def self.remove_from_exclusion_list(user_id)
    setting = find_by(user_id: user_id, setting_type: 'exclusion')
    setting&.update(active: false) || true
  end

  # Add a user as super user
  # @param user_id [Integer] User ID to make super user
  # @param notes [String] Optional notes
  # @return [TaTeamSetting] The created or updated setting
  def self.add_super_user(user_id, notes: nil)
    setting = find_or_initialize_by(user_id: user_id, setting_type: 'super_user')
    setting.active = true
    setting.notes = notes if notes
    setting.save
    setting
  end

  # Remove super user status
  # @param user_id [Integer] User ID to remove
  # @return [Boolean] true if removed successfully
  def self.remove_super_user(user_id)
    setting = find_by(user_id: user_id, setting_type: 'super_user')
    setting&.update(active: false) || true
  end

  # Get all users in exclusion list with details
  # @return [ActiveRecord::Relation] Users with exclusion settings
  def self.excluded_users
    exclusions.includes(:user)
  end

  # Get all super users with details
  # @return [ActiveRecord::Relation] Users with super_user settings
  def self.super_users_list
    super_users.includes(:user)
  end

  # Instance Methods

  # Global support Redmine integration settings
  def self.support_redmine_settings
    raw = Setting.plugin_redmine_time_analytics || {}
    {
      base_url: raw['support_redmine_base_url'].to_s.strip,
      api_key: raw['support_redmine_api_key'].to_s
    }
  end

  def self.support_redmine_configured?
    cfg = support_redmine_settings
    cfg[:base_url].present? && cfg[:api_key].present?
  end

  def self.update_support_redmine_settings(base_url:, api_key:)
    settings = (Setting.plugin_redmine_time_analytics || {}).dup

    settings['support_redmine_base_url'] = base_url.to_s.strip.sub(%r{/\z}, '')
    if api_key.present?
      settings['support_redmine_api_key'] = api_key.to_s.strip
    end

    Setting.plugin_redmine_time_analytics = settings
  end

  # Check if this setting is for exclusion
  # @return [Boolean] true if setting_type is 'exclusion'
  def exclusion?
    setting_type == 'exclusion'
  end

  def active_on?(date)
    return false unless exclusion? && active? && start_date.present?

    start_date <= date && (end_date.nil? || end_date >= date)
  end

  def date_range_label
    return '' unless exclusion?
    return '' unless start_date.present?

    if end_date.present?
      "#{start_date.strftime('%Y-%m-%d')} to #{end_date.strftime('%Y-%m-%d')}"
    else
      "#{start_date.strftime('%Y-%m-%d')} to present"
    end
  end

  def end_date_display
    end_date.presence || 'Ongoing'
  end

  # Check if this setting is for super user
  # @return [Boolean] true if setting_type is 'super_user'
  def super_user?
    setting_type == 'super_user'
  end

  # Toggle active status
  # @return [Boolean] true if saved successfully
  def toggle_active!
    update(active: !active)
  end

  private

  def end_date_after_start_date
    return if start_date.blank? || end_date.blank?

    errors.add(:end_date, 'must be after start date') if end_date < start_date
  end

  def default_exclusion_start_date
    self.start_date = Date.current if start_date.blank?
  end

  public

  # Get user name (convenience method)
  # @return [String] User's name or login
  def user_name
    user&.name || user&.login || 'Unknown User'
  end

  # Get formatted setting type for display
  # @return [String] Human-readable setting type
  def setting_type_label
    case setting_type
    when 'exclusion'
      'Excluded from Analytics'
    when 'super_user'
      'Super User (View All Teams)'
    else
      setting_type.titleize
    end
  end
end
