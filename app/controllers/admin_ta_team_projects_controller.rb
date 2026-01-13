class AdminTaTeamProjectsController < ApplicationController
  layout 'admin'
  self.main_menu = false

  before_action :require_admin
  before_action :find_team
  before_action :find_team_project, only: [:edit, :update, :destroy]

  helper :ta_teams

  def index
    @active_projects = @team.ta_team_projects.active.includes(:project).order('start_date DESC')
    @inactive_projects = @team.ta_team_projects.inactive.includes(:project).order('end_date DESC')
  end

  def new
    @team_project = @team.ta_team_projects.build
    @available_projects = Project.active.sorted.where.not(
      id: @team.ta_team_projects.active.pluck(:project_id)
    )
  end

  def create
    @team_project = @team.ta_team_projects.build
    @team_project.attributes = team_project_params

    if @team_project.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to admin_ta_team_team_projects_path(@team)
    else
      @available_projects = Project.active.sorted.where.not(
        id: @team.ta_team_projects.active.pluck(:project_id)
      )
      render :new
    end
  end

  def edit
    @available_projects = Project.active.sorted
  end

  def update
    if @team_project.update(team_project_params)
      flash[:notice] = l(:notice_successful_update)
      redirect_to admin_ta_team_team_projects_path(@team)
    else
      @available_projects = Project.active.sorted
      render :edit
    end
  end

  def destroy
    @team_project.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to admin_ta_team_team_projects_path(@team)
  end

  private

  def find_team
    @team = TaTeam.find(params[:admin_ta_team_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_team_project
    @team_project = @team.ta_team_projects.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def team_project_params
    params.require(:ta_team_project).permit(:project_id, :start_date, :end_date)
  end
end
