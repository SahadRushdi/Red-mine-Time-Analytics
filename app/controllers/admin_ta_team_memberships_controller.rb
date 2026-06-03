class AdminTaTeamMembershipsController < ApplicationController
  layout 'admin'
  menu_item :team_analytics_configuration
  self.main_menu = false

  before_action :require_admin
  before_action :find_team
  before_action :find_membership, only: [:update, :destroy, :move]

  helper :ta_teams

  def create
    @membership = @team.ta_team_memberships.build
    @membership.attributes = membership_params

    if @membership.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to admin_ta_teams_path(main_tab: params[:main_tab].presence || 'structure')
    else
      flash[:error] = @membership.errors.full_messages.to_sentence
      redirect_to admin_ta_teams_path(
        main_tab: params[:main_tab].presence || 'structure',
        open_add_member_modal: 1,
        add_member_team_id: @team.id
      )
    end
  end

  def update
    if @membership.update(membership_params)
      flash[:notice] = l(:notice_successful_update)
      redirect_membership_context
    else
      flash[:error] = @membership.errors.full_messages.to_sentence
      redirect_membership_context
    end
  end

  def destroy
    @membership.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_membership_context
  end

  def move
    target_team_id = params[:target_team_id]
    @target_team = TaTeam.find(target_team_id)
    move_mode = params[:move_mode] # 'move' or 'inactivate_and_add'

    ActiveRecord::Base.transaction do
      if move_mode == 'move'
        # Requirement 1: Delete from current team and add to new team
        user_id = @membership.user_id
        role = @membership.role
        @membership.destroy!

        @new_membership = @target_team.ta_team_memberships.create!(
          user_id: user_id,
          role: role,
          start_date: Date.today
        )
      else
        # Requirement 2: Inactivate in current team and add to new team
        @membership.update!(end_date: Date.today)

        @new_membership = @target_team.ta_team_memberships.create!(
          user_id: @membership.user_id,
          role: @membership.role,
          start_date: Date.today
        )
      end
    end

    flash[:notice] = "Member successfully moved to #{@target_team.name}"
    redirect_to admin_ta_teams_path(main_tab: 'structure')
  rescue ActiveRecord::RecordInvalid => e
    flash[:error] = e.record.errors.full_messages.to_sentence
    redirect_to admin_ta_teams_path(main_tab: 'structure')
  rescue StandardError => e
    flash[:error] = e.message
    redirect_to admin_ta_teams_path(main_tab: 'structure')
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

  def redirect_membership_context
    if params[:main_tab].present?
      redirect_params = { main_tab: params[:main_tab] }
      redirect_params[:sidebar_tab] = params[:sidebar_tab] if params[:sidebar_tab].present?
      redirect_params[:page] = params[:page] if params[:page].present?

      redirect_to admin_ta_teams_path(redirect_params)
    else
      redirect_back fallback_location: admin_ta_team_path(@team)
    end
  end
end
