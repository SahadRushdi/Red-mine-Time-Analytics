require 'uri'

class AdminTaTeamSettingsController < ApplicationController
  layout 'admin'
  menu_item :team_analytics_configuration
  self.main_menu = false

  before_action :require_admin

  def index
    @excluded_users = User.where(id: TaTeamSetting.excluded_user_ids).sorted
    @super_users = User.where(id: TaTeamSetting.super_user_ids).sorted
    @available_users = User.active.sorted
    @exclusion_settings_by_user_id = TaTeamSetting.exclusions.pluck(:user_id, :id).to_h
    @super_user_settings_by_user_id = TaTeamSetting.super_users.pluck(:user_id, :id).to_h
    @support_redmine_settings = TaTeamSetting.support_redmine_settings
    @support_redmine_configured = TaTeamSetting.support_redmine_configured?
  end

  def create
    setting_type = params[:setting_type]

    if setting_type == 'support_redmine'
      support_params = support_redmine_params
      base_url = support_params[:support_redmine_base_url].to_s.strip
      api_key = support_params[:support_redmine_api_key].to_s.strip

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

    user_id = params[:user_id].to_i

    if user_id.blank? || user_id.zero?
      flash[:error] = "Please select a user"
      redirect_to admin_ta_team_settings_path
      return
    end

    case setting_type
    when 'exclusion'
      if TaTeamSetting.excluded_user_ids.include?(user_id)
        flash[:warning] = "User is already in exclusion list"
      else
        setting = TaTeamSetting.create(setting_type: 'exclusion', user_id: user_id)
        if setting.persisted?
          flash[:notice] = "User added to exclusion list"
        else
          flash[:error] = "Failed to add user: #{setting.errors.full_messages.join(', ')}"
        end
      end
    when 'super_user'
      if TaTeamSetting.super_user_ids.include?(user_id)
        flash[:warning] = "User is already a super user"
      else
        setting = TaTeamSetting.create(setting_type: 'super_user', user_id: user_id)
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

  def support_redmine_params
    params.permit(:support_redmine_base_url, :support_redmine_api_key)
  end
end
