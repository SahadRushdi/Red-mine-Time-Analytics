class AdminTaTeamsController < ApplicationController
  layout 'admin'
  self.main_menu = false

  before_action :require_admin
  before_action :find_team, only: [:show, :edit, :update, :destroy]

  helper :ta_teams

  def index
    @root_teams = TaTeam.root_teams.ordered_by_name
    @all_teams = TaTeam.ordered_by_name.to_a
  end

  def show
    @memberships = @team.ta_team_memberships.includes(:user).order('start_date DESC')
    @projects = @team.ta_team_projects.includes(:project).order('start_date DESC')
  end

  def new
    @team = TaTeam.new
    @available_parents = TaTeam.ordered_by_name
  end

  def create
    @team = TaTeam.new
    @team.safe_attributes = params[:ta_team]

    if @team.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to admin_ta_teams_path
    else
      @available_parents = TaTeam.ordered_by_name
      render :new
    end
  end

  def edit
    @available_parents = TaTeam.where.not(id: [@team.id] + @team.all_descendants.pluck(:id)).ordered_by_name
  end

  def update
    @team.safe_attributes = params[:ta_team]

    if @team.save
      flash[:notice] = l(:notice_successful_update)
      redirect_to admin_ta_teams_path
    else
      @available_parents = TaTeam.where.not(id: [@team.id] + @team.all_descendants.pluck(:id)).ordered_by_name
      render :edit
    end
  end

  def destroy
    if @team.children.any?
      flash[:error] = "Cannot delete team with sub-teams. Please delete or reassign sub-teams first."
      redirect_to admin_ta_teams_path
      return
    end

    if @team.ta_team_memberships.active.any?
      flash[:error] = "Cannot delete team with active members. Please remove all members first."
      redirect_to admin_ta_teams_path
      return
    end

    @team.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to admin_ta_teams_path
  end

  private

  def find_team
    @team = TaTeam.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
