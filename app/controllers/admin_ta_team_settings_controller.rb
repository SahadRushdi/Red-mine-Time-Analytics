class AdminTaTeamSettingsController < ApplicationController
  layout 'admin'
  self.main_menu = false

  before_action :require_admin

  def index
    @excluded_users = User.where(id: TaTeamSetting.excluded_user_ids).sorted
    @super_users = User.where(id: TaTeamSetting.super_user_ids).sorted
    @available_users = User.active.sorted
  end

  def create
    setting_type = params[:setting_type]
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
end
