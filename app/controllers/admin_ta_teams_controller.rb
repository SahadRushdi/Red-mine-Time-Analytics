class AdminTaTeamsController < ApplicationController
  layout 'admin'
  menu_item :team_analytics_configuration
  self.main_menu = false

  before_action :require_admin
  before_action :find_team, only: [:show, :edit, :update, :destroy]

  helper :ta_teams

  def index
    @all_teams = TaTeam.ordered_by_name.to_a
    @team_children_map = @all_teams.group_by(&:parent_team_id)
    @root_teams = @team_children_map[nil] || []
    @team_active_member_counts = TaTeamMembership.active.group(:team_id).count
    @team_open_hiring_counts = TaHiringNeed.open.group(:team_id).count
    @active_memberships = TaTeamMembership.active.includes(:user, :team).references(:user)
                                        .order('users.firstname ASC, users.lastname ASC')
    @allocated_user_ids = @active_memberships.map(&:user_id).uniq
    @unallocated_users = User.active.sorted.where.not(id: @allocated_user_ids)
    @open_hiring_needs = TaHiringNeed.open.includes(:team).ordered_priority
    @hiring_need_history = TaHiringNeed.includes(:team).ordered_by_recent
    @new_hiring_need = TaHiringNeed.new(priority: 'medium')
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
    
    # Handle personal_project_urls array
    team_params = params[:ta_team].dup
    if team_params[:personal_project_urls].is_a?(Array)
      team_params[:personal_project_urls] = team_params[:personal_project_urls].reject(&:blank?).to_json
    end
    
    @team.safe_attributes = team_params

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
    # Handle personal_project_urls array
    team_params = params[:ta_team].dup
    if team_params[:personal_project_urls].is_a?(Array)
      team_params[:personal_project_urls] = team_params[:personal_project_urls].reject(&:blank?).to_json
    end
    
    @team.safe_attributes = team_params

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

  def validate_url
    url = params[:url]
    
    if url.blank?
      render json: { valid: false, error: 'URL is required' }
      return
    end
    
    # Extract project identifier
    match = url.match(/\/projects\/([a-z0-9\-_]+)/i)
    if match.nil?
      render json: { valid: false, error: 'Invalid URL format. Expected: http://host/projects/project-identifier' }
      return
    end
    
    identifier = match[1]
    project = Project.find_by(identifier: identifier, status: Project::STATUS_ACTIVE)
    
    if project.nil?
      render json: { valid: false, error: 'Project not found or inactive in this Redmine instance' }
      return
    end
    
    render json: { valid: true, project_name: project.name, identifier: identifier }
  end

  def assign_member
    user = User.active.find(params[:user_id])
    team = TaTeam.find(params[:team_id])
    role = params[:role].presence
    role = TaTeamMembership::ROLES.include?(role) ? role : 'member'

    membership = team.ta_team_memberships.build(
      user: user,
      role: role,
      start_date: Date.today
    )

    if membership.save
      flash[:notice] = l(:notice_successful_create)
    else
      flash[:error] = membership.errors.full_messages.join(', ')
    end
  rescue ActiveRecord::RecordNotFound
    flash[:error] = l(:label_no_data)
  ensure
    redirect_to admin_ta_teams_path
  end

  def create_hiring_need
    safe_params = hiring_need_params
    safe_params[:role] = 'Team Member' if TaHiringNeed.column_names.include?('role')
    hiring_need = TaHiringNeed.new(safe_params.merge(status: 'open'))

    if hiring_need.save
      flash[:notice] = l(:notice_successful_create)
    else
      flash[:error] = hiring_need.errors.full_messages.join(', ')
    end

    redirect_to admin_ta_teams_path
  end

  private

  def find_team
    @team = TaTeam.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def hiring_need_params
    params.require(:ta_hiring_need).permit(:position_title, :team_id, :priority)
  end
end
