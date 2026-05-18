class AdminTaTeamMembershipsController < ApplicationController
  layout 'admin'
  menu_item :team_analytics_configuration
  self.main_menu = false

  before_action :require_admin
  before_action :find_team
  before_action :find_membership, only: [:update, :destroy]

  helper :ta_teams

  def create
    @membership = @team.ta_team_memberships.build
    @membership.attributes = membership_params

    if @membership.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to admin_ta_teams_path(main_tab: 'members')
    else
      flash[:error] = @membership.errors.full_messages.to_sentence
      redirect_to admin_ta_teams_path(
        main_tab: 'members',
        open_add_member_modal: 1,
        add_member_team_id: @team.id
      )
    end
  end

  def update
    if @membership.update(membership_params)
      flash[:notice] = l(:notice_successful_update)
      redirect_to admin_ta_teams_path(main_tab: 'members')
    else
      flash[:error] = @membership.errors.full_messages.to_sentence
      redirect_to admin_ta_teams_path(main_tab: 'members')
    end
  end

  def destroy
    @membership.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to admin_ta_teams_path(main_tab: 'members')
  end

  private

  def find_team
    @team = TaTeam.find(params[:admin_ta_team_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_membership
    @membership = @team.ta_team_memberships.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def membership_params
    params.require(:ta_team_membership).permit(:user_id, :role, :start_date, :end_date)
  end
end
