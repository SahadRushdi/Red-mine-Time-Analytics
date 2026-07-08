class AdminTaTeamProjectsController < ApplicationController
  layout 'admin'
  menu_item :team_analytics_configuration
  self.main_menu = false

  before_action :require_admin
  before_action :find_team
  before_action :find_team_project, only: [:edit, :update, :destroy]

  helper :ta_teams

  def index
    @team_project = @team.ta_team_projects.build
    load_available_projects
    load_projects
    load_inherited_projects
    @show_add_project_modal = params[:open_add_project_modal].present?
  end

  def new
    redirect_to admin_ta_team_team_projects_path(@team, open_add_project_modal: 1)
  end

  def create
    @team_project = @team.ta_team_projects.build
    @team_project.attributes = team_project_params

    if @team_project.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to admin_ta_team_team_projects_path(@team)
    else
      # Redirect back to `index` (a fresh GET) instead of re-rendering it directly here - `index`
      # sets up several ivars (e.g. @inherited_projects) that this action never needed before, and
      # re-rendering its template without them raised a NoMethodError (e.g. assigning a project
      # whose URL/identifier is already active for this team, which fails validation and used to
      # crash instead of showing the validation message).
      flash[:error] = @team_project.errors.full_messages.to_sentence
      redirect_to admin_ta_team_team_projects_path(@team, open_add_project_modal: 1)
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

  # Toggles whether Support Time (external project hours) is calculated/shown for this team.
  # When enabled, both directly-assigned and inherited-from-child-team external projects are
  # excluded from the Support Time calculation on the Team dashboard.
  def toggle_support_time
    @team.update(hide_support_time: params[:hide_support_time] == '1')
    redirect_to admin_ta_team_team_projects_path(@team)
  end

  private

  def load_projects
    @active_projects = @team.ta_team_projects.active.includes(:project).order('start_date DESC')
    @inactive_projects = @team.ta_team_projects.inactive.includes(:project).order('end_date DESC')
  end

  def load_inherited_projects
    # Get inherited projects from child teams
    @inherited_projects = @team.inherited_projects(Date.current, Date.current)
  end

  def load_available_projects
    assigned_local_ids = @team.ta_team_projects.active.where(source_type: [nil, 'local']).where.not(project_id: nil).pluck(:project_id)
    @available_projects = Project.active.sorted.where.not(id: assigned_local_ids)
  end

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
    params.require(:ta_team_project).permit(:source_type, :project_id, :external_project_url, :start_date, :end_date)
  end
end
