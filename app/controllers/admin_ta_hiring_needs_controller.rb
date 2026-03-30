class AdminTaHiringNeedsController < ApplicationController
  layout 'admin'
  menu_item :team_analytics_configuration
  self.main_menu = false

  before_action :require_admin
  before_action :find_hiring_need

  def mark_filled
    @hiring_need.mark_filled!
    flash[:notice] = l(:notice_successful_update)
  rescue ActiveRecord::RecordInvalid
    flash[:error] = @hiring_need.errors.full_messages.join(', ')
  ensure
    redirect_to admin_ta_teams_path
  end

  private

  def find_hiring_need
    @hiring_need = TaHiringNeed.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
