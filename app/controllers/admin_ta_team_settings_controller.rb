require 'uri'

class AdminTaTeamSettingsController < ApplicationController
  layout 'admin'
  menu_item :team_analytics_configuration
  self.main_menu = false

  before_action :require_admin

  def index
    @excluded_settings = TaTeamSetting.exclusions.includes(:user).to_a.sort_by { |setting| setting.user_name.to_s.downcase }
    @excluded_users = @excluded_settings.map(&:user).compact
    @super_users = User.where(id: TaTeamSetting.super_user_ids).sorted
    @available_users = User.active.sorted
    @exclusion_settings_by_user_id = @excluded_settings.index_by(&:user_id)
    @super_user_settings_by_user_id = TaTeamSetting.super_users.pluck(:user_id, :id).to_h
    @support_redmine_settings = TaTeamSetting.support_redmine_settings
    @support_redmine_configured = TaTeamSetting.support_redmine_configured?
    @my_team_enabled = TaTeamSetting.my_team_enabled?
  end

  def create
    setting_type = team_setting_params[:setting_type]

    if setting_type == 'my_team_visibility'
      enabled = team_setting_params[:my_team_enabled] == '1'
      TaTeamSetting.update_my_team_enabled(enabled)
      flash[:notice] = "My Team page #{enabled ? 'activated' : 'deactivated'} successfully"
      redirect_to admin_ta_team_settings_path
      return
    end

    if setting_type == 'support_redmine'
      base_url = team_setting_params[:support_redmine_base_url].to_s.strip
      api_key = team_setting_params[:support_redmine_api_key].to_s.strip

      begin
        validate_support_base_url!(base_url)
        TaTeamSetting.update_support_redmine_settings(base_url: base_url, api_key: api_key)
        flash[:notice] = 'Support Redmine settings updated'
      rescue ArgumentError => e
        flash[:error] = e.message
      end

      redirect_to admin_ta_team_settings_path
      return
    end

    user_id = team_setting_params[:user_id].to_i

    if user_id.blank? || user_id.zero?
      flash[:error] = "Please select a user"
      redirect_to admin_ta_team_settings_path
      return
    end

    case setting_type
    when 'exclusion'
      start_date = parse_admin_setting_date(team_setting_params[:start_date]) || Date.current
      end_date = parse_admin_setting_date(team_setting_params[:end_date])
      setting = TaTeamSetting.add_to_exclusion_list(user_id, start_date: start_date, end_date: end_date)

      if setting.persisted?
        flash[:notice] = setting.previously_new_record? ? "User added to exclusion list" : "Exclusion dates updated"
      else
        flash[:error] = "Failed to add user: #{setting.errors.full_messages.join(', ')}"
      end
    when 'super_user'
      if TaTeamSetting.super_user_ids.include?(user_id)
        flash[:warning] = "User is already a super user"
      else
        setting = TaTeamSetting.add_super_user(user_id)
        if setting.persisted?
          flash[:notice] = "User added as super user"
        else
          flash[:error] = "Failed to add user: #{setting.errors.full_messages.join(', ')}"
        end
      end
    else
      flash[:error] = "Invalid setting type"
    end

    redirect_to admin_ta_team_settings_path
  end

  def destroy
    setting = TaTeamSetting.find(params[:id])
    setting.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to admin_ta_team_settings_path
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  private

  def validate_support_base_url!(base_url)
    raise ArgumentError, 'Support Redmine base URL is required' if base_url.blank?

    uri = URI.parse(base_url)
    unless uri.is_a?(URI::HTTP) && uri.host.present?
      raise ArgumentError, 'Support Redmine base URL must be a valid http(s) URL'
    end
  rescue URI::InvalidURIError
    raise ArgumentError, 'Support Redmine base URL must be a valid http(s) URL'
  end

  def team_setting_params
    params.permit(:setting_type, :user_id, :start_date, :end_date, :support_redmine_base_url, :support_redmine_api_key, :my_team_enabled)
  end

  def parse_admin_setting_date(value)
    return nil if value.blank?

    Date.strptime(value, '%m/%d/%Y')
  rescue ArgumentError
    Date.parse(value)
  end
end
