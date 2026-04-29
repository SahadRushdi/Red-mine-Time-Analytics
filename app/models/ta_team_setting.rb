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

  # Scopes
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :exclusions, -> { where(setting_type: 'exclusion', active: true) }
  scope :super_users, -> { where(setting_type: 'super_user', active: true) }

  # Class Methods

  # Get array of user IDs that should be excluded from analytics
  # @return [Array<Integer>] User IDs in exclusion list
  def self.excluded_user_ids
    exclusions.pluck(:user_id)
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
  def self.add_to_exclusion_list(user_id, notes: nil)
    setting = find_or_initialize_by(user_id: user_id, setting_type: 'exclusion')
    setting.active = true
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

  def self.leave_sync_settings
    raw = Setting.plugin_redmine_time_analytics || {}
    {
      enabled: raw['leave_sync_enabled'].to_s == '1',
      recipient_email: raw['leave_sync_recipient_email'].to_s.strip.presence || 'vacation-group@entgra.io',
      historical_sync_start_date: parse_date_setting(raw['leave_sync_start_date']),
      gmail_delegated_user: raw['leave_gmail_delegated_user'].to_s.strip,
      gmail_service_account_json: raw['leave_gmail_service_account_json'].to_s,
      last_synced_at: parse_time_setting(raw['leave_sync_last_synced_at']),
      last_sync_mode: raw['leave_sync_last_mode'].to_s
    }
  end

  def self.update_leave_sync_settings!(enabled:, recipient_email:, historical_sync_start_date:, gmail_delegated_user:, gmail_service_account_json:)
    normalized_recipient = recipient_email.to_s.strip.downcase
    normalized_delegated_user = gmail_delegated_user.to_s.strip.downcase
    raise ArgumentError, 'Leave recipient email is required' if normalized_recipient.blank?
    raise ArgumentError, 'Leave recipient email must be valid' unless normalized_recipient.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
    if normalized_delegated_user.present? && !normalized_delegated_user.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
      raise ArgumentError, 'Gmail delegated user must be a valid email'
    end

    if historical_sync_start_date.present?
      begin
        Date.parse(historical_sync_start_date.to_s)
      rescue ArgumentError
        raise ArgumentError, 'Historical sync start date is invalid'
      end
    end

    settings = (Setting.plugin_redmine_time_analytics || {}).dup
    settings['leave_sync_enabled'] = enabled.to_s == '1' ? '1' : '0'
    settings['leave_sync_recipient_email'] = normalized_recipient
    settings['leave_sync_start_date'] = historical_sync_start_date.to_s
    settings['leave_gmail_delegated_user'] = normalized_delegated_user
    if gmail_service_account_json.present?
      settings['leave_gmail_service_account_json'] = gmail_service_account_json
    end
    Setting.plugin_redmine_time_analytics = settings
  end

  def self.update_leave_sync_runtime!(last_synced_at:, last_sync_mode:)
    settings = (Setting.plugin_redmine_time_analytics || {}).dup
    settings['leave_sync_last_synced_at'] = last_synced_at.iso8601
    settings['leave_sync_last_mode'] = last_sync_mode.to_s
    Setting.plugin_redmine_time_analytics = settings
  end

  def self.leave_sync_configured?
    config = leave_sync_settings
    config[:recipient_email].present? && config[:gmail_delegated_user].present? && config[:gmail_service_account_json].present?
  end

  def self.parse_date_setting(value)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def self.parse_time_setting(value)
    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end

  # Check if this setting is for exclusion
  # @return [Boolean] true if setting_type is 'exclusion'
  def exclusion?
    setting_type == 'exclusion'
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
