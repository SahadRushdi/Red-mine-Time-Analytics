class AdminTaTeamMembershipsController < ApplicationController
  layout 'admin'
  self.main_menu = false

  before_action :require_admin
  before_action :find_team
  before_action :find_membership, only: [:edit, :update, :destroy]

  helper :ta_teams

  def index
    @active_memberships = @team.ta_team_memberships.active.includes(:user).order('start_date DESC')
    @inactive_memberships = @team.ta_team_memberships.inactive.includes(:user).order('end_date DESC')
  end

  def new
    @membership = @team.ta_team_memberships.build
    @available_users = User.active.sorted.where.not(
      id: @team.ta_team_memberships.active.pluck(:user_id)
    )
  end

  def create
    @membership = @team.ta_team_memberships.build
    @membership.attributes = membership_params

    if @membership.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to admin_ta_team_memberships_path(@team)
    else
      @available_users = User.active.sorted.where.not(
        id: @team.ta_team_memberships.active.pluck(:user_id)
      )
      render :new
    end
  end

  def edit
    @available_users = User.active.sorted
  end

  def update
    if @membership.update(membership_params)
      flash[:notice] = l(:notice_successful_update)
      redirect_to admin_ta_team_memberships_path(@team)
    else
      @available_users = User.active.sorted
      render :edit
    end
  end

  def destroy
    @membership.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to admin_ta_team_memberships_path(@team)
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
