# frozen_string_literal: true

require 'fugit'

# TaTeamSetting model represents plugin settings for users
# Used for exclusion list (users whose time logs are ignored) and super users (can view all teams)
class TaTeamSetting < ActiveRecord::Base
  self.table_name = 'ta_team_settings'

  # Constants
  SETTING_TYPES = %w[exclusion super_user].freeze
  LEAVE_APPROACHES = %w[oauth].freeze
  AI_PROVIDERS = %w[google].freeze
  DEFAULT_LEAVE_SYNC_CRON = '*/10 * * * *'

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

  def self.my_team_enabled?
    raw = Setting.plugin_redmine_time_analytics || {}
    raw['my_team_enabled'].to_s == '1'
  end

  def self.update_my_team_enabled(enabled)
    settings = (Setting.plugin_redmine_time_analytics || {}).dup
    settings['my_team_enabled'] = (enabled.to_s == '1' || enabled == true) ? '1' : '0'
    Setting.plugin_redmine_time_analytics = settings
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
    approach = 'oauth'

    oauth_client_secret_raw = raw['leave_oauth_client_secret_enc'].presence || raw['leave_oauth_client_secret'].to_s
    oauth_refresh_token_raw = raw['leave_oauth_refresh_token_enc'].presence || raw['leave_oauth_refresh_token'].to_s
    ai_api_key_raw = raw['leave_ai_api_key_enc'].presence || raw['leave_ai_api_key'].to_s

    {
      enabled: raw['leave_sync_enabled'].to_s == '1',
      recipient_email: raw['leave_sync_recipient_email'].to_s.strip.presence || 'vacation-group@entgra.io',
      historical_sync_start_date: parse_date_setting(raw['leave_sync_start_date']),
      historical_sync_end_date: parse_date_setting(raw['leave_sync_end_date']),
      leave_approach: approach,
      oauth_client_id: raw['leave_oauth_client_id'].to_s.strip,
      oauth_client_secret: decrypt_value(oauth_client_secret_raw),
      oauth_refresh_token: decrypt_value(oauth_refresh_token_raw),
      oauth_account_email: raw['leave_oauth_account_email'].to_s.strip,
      ai_extraction_enabled: raw['leave_ai_extraction_enabled'].to_s == '1',
      ai_provider: 'google',
      ai_model: raw['leave_ai_model'].to_s.strip,
      ai_api_key: decrypt_value(ai_api_key_raw),
      last_synced_at: parse_time_setting(raw['leave_sync_last_synced_at']),
      last_sync_mode: raw['leave_sync_last_mode'].to_s,
      cron: raw['leave_sync_cron'].to_s.strip.presence || DEFAULT_LEAVE_SYNC_CRON
    }
  end

  def self.default_leave_sync_cron
    DEFAULT_LEAVE_SYNC_CRON
  end

  def self.update_leave_sync_settings!(
    enabled:,
    recipient_email:,
    historical_sync_start_date:,
    historical_sync_end_date: nil,
    leave_approach: 'oauth',
    oauth_client_id: nil,
    oauth_client_secret: nil,
    oauth_account_email: nil,
    leave_sync_cron: nil,
    ai_extraction_enabled: nil,
    ai_provider: 'google',
    ai_model: nil,
    ai_api_key: nil
  )
    normalized_recipient = recipient_email.to_s.strip.downcase
    raise ArgumentError, 'Leave recipient email is required' if normalized_recipient.blank?
    raise ArgumentError, 'Leave recipient email must be valid' unless normalized_recipient.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)

    if historical_sync_start_date.present?
      start_date = safe_parse_date(historical_sync_start_date)
      raise ArgumentError, 'Historical sync start date is invalid' if start_date.nil?
    end
    if historical_sync_end_date.present?
      end_date = safe_parse_date(historical_sync_end_date)
      raise ArgumentError, 'Historical sync end date is invalid' if end_date.nil?
    end

    if historical_sync_start_date.present? && historical_sync_end_date.present?
      s_date = safe_parse_date(historical_sync_start_date)
      e_date = safe_parse_date(historical_sync_end_date)
      raise ArgumentError, 'Historical sync end date must be on or after start date' if e_date < s_date
    end
    if historical_sync_end_date.present? && historical_sync_start_date.blank?
      raise ArgumentError, 'Historical sync start date is required when an end date is provided'
    end

    normalized_oauth_account = oauth_account_email.to_s.strip.downcase
    if normalized_oauth_account.present? && !normalized_oauth_account.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
      raise ArgumentError, 'OAuth account email must be valid'
    end

    settings = (Setting.plugin_redmine_time_analytics || {}).dup
    settings['leave_sync_enabled'] = enabled.to_s == '1' ? '1' : '0'
    settings['leave_sync_recipient_email'] = normalized_recipient
    settings['leave_sync_start_date'] = historical_sync_start_date.to_s
    settings['leave_sync_end_date'] = historical_sync_end_date.to_s
    settings['leave_sync_approach'] = 'oauth'
    cron_expression = leave_sync_cron.to_s.strip.presence || DEFAULT_LEAVE_SYNC_CRON
    settings['leave_sync_cron'] = cron_expression
    settings['leave_ai_extraction_enabled'] = ai_extraction_enabled.to_s == '1' ? '1' : '0'
    settings['leave_ai_provider'] = 'google'
    settings['leave_ai_model'] = ai_model.to_s.strip

    settings['leave_oauth_client_id'] = oauth_client_id.to_s.strip
    settings['leave_oauth_account_email'] = normalized_oauth_account
    if oauth_client_secret.present?
      settings['leave_oauth_client_secret_enc'] = encrypt_value(oauth_client_secret.to_s)
    end

    settings['leave_ai_api_key_enc'] = encrypt_value(ai_api_key.to_s) if ai_api_key.present?

    validate_leave_sync_config!(settings)
    validate_leave_sync_cron!(settings)
    validate_leave_ai_config!(settings)
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
    return false if config[:recipient_email].blank?

    config[:oauth_client_id].present? &&
      config[:oauth_client_secret].present? &&
      config[:oauth_account_email].present? &&
      config[:oauth_refresh_token].present?
  end

  def self.leave_sync_manual_pull?
    true
  end

  def self.leave_ai_configured?
    config = leave_sync_settings
    return false unless config[:ai_extraction_enabled]
    return false unless AI_PROVIDERS.include?(config[:ai_provider].to_s)

    config[:ai_model].present? && config[:ai_api_key].present?
  end

  def self.update_leave_oauth_refresh_token!(refresh_token:, account_email: nil)
    token = refresh_token.to_s.strip
    raise ArgumentError, 'Refresh token is required' if token.blank?

    settings = (Setting.plugin_redmine_time_analytics || {}).dup
    settings['leave_oauth_refresh_token_enc'] = encrypt_value(token)
    settings['leave_sync_approach'] = 'oauth'
    if account_email.present?
      normalized_account = account_email.to_s.strip.downcase
      raise ArgumentError, 'OAuth account email must be valid' unless normalized_account.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)

      settings['leave_oauth_account_email'] = normalized_account
    end
    Setting.plugin_redmine_time_analytics = settings
  end

  def self.parse_date_setting(value)
    safe_parse_date(value.to_s)
  end

  def self.safe_parse_date(value)
    return nil if value.blank?
    begin
      # Try MM/DD/YYYY first (standard for the date pickers in this plugin)
      Date.strptime(value.to_s, '%m/%d/%Y')
    rescue ArgumentError
      begin
        Date.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end

  def self.parse_time_setting(value)
    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end

  def self.encrypt_value(value)
    plain = value.to_s
    return plain if plain.blank?

    if defined?(Redmine::Ciphering)
      return Redmine::Ciphering.encrypt_text(plain) if Redmine::Ciphering.respond_to?(:encrypt_text)
      return Redmine::Ciphering.encrypt(plain) if Redmine::Ciphering.respond_to?(:encrypt)
    end

    plain
  end

  def self.decrypt_value(value)
    encrypted = value.to_s
    return encrypted if encrypted.blank?

    if defined?(Redmine::Ciphering)
      return Redmine::Ciphering.decrypt_text(encrypted) if Redmine::Ciphering.respond_to?(:decrypt_text)
      return Redmine::Ciphering.decrypt(encrypted) if Redmine::Ciphering.respond_to?(:decrypt)
    end

    encrypted
  rescue StandardError
    encrypted
  end

  def self.validate_leave_sync_config!(settings)
    client_id = settings['leave_oauth_client_id'].to_s.strip
    client_secret = decrypt_value(settings['leave_oauth_client_secret_enc'].to_s)
    account_email = settings['leave_oauth_account_email'].to_s.strip
    raise ArgumentError, 'OAuth client ID is required' if client_id.blank?
    raise ArgumentError, 'OAuth client secret is required' if client_secret.blank?
    raise ArgumentError, 'OAuth account email is required' if account_email.blank?
  end

  def self.validate_leave_ai_config!(settings)
    return unless settings['leave_ai_extraction_enabled'].to_s == '1'

    model = settings['leave_ai_model'].to_s.strip
    api_key = decrypt_value(settings['leave_ai_api_key_enc'].to_s)

    raise ArgumentError, 'AI model is required when AI extraction is enabled' if model.blank?
    raise ArgumentError, 'AI API key is required when AI extraction is enabled' if api_key.blank?
  end

  def self.validate_leave_sync_cron!(settings)
    cron = settings['leave_sync_cron'].to_s.strip
    raise ArgumentError, 'Leave sync cron expression is required' if cron.blank?

    Fugit::Cron.parse(cron)
  rescue StandardError
    raise ArgumentError, 'Leave sync cron expression is invalid'
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
