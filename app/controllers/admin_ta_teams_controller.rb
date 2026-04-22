class AdminTaTeamsController < ApplicationController
  layout 'admin'
  menu_item :team_analytics_configuration
  self.main_menu = false

  before_action :require_admin
  before_action :find_team, only: [:show, :edit, :update, :destroy]

  helper :ta_teams

  def index
    @all_teams = TaTeam.ordered_by_name.to_a
    @active_main_tab = params[:main_tab].presence || 'structure'
    @show_add_member_modal = params[:open_add_member_modal].present?
    @selected_add_member_team_id = params[:add_member_team_id].presence
    @add_member_membership = TaTeamMembership.new(start_date: Date.current, role: 'member')
    @add_member_available_users = User.active.sorted
    @team_children_map = @all_teams.group_by(&:parent_team_id)
    @root_teams = @team_children_map[nil] || []
    @team_active_member_counts = TaTeamMembership.active.group(:team_id).count
    @team_open_hiring_counts = TaHiringNeed.open.group(:team_id).count
    @active_memberships = TaTeamMembership.active.includes(:user, :team).references(:user)
                                        .order('users.firstname ASC, users.lastname ASC')
    @team_active_memberships_map = @active_memberships.group_by(&:team_id)
    @allocated_user_ids = @active_memberships.map(&:user_id).uniq
    @unallocated_users = User.active.sorted.where.not(id: @allocated_user_ids)
    @open_hiring_needs = TaHiringNeed.open.includes(:team).ordered_priority
    @member_history_groups = build_member_history_groups
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

    # If schema migration hasn't been applied yet (team_id still NOT NULL),
    # nullifying hiring history during team deletion will fail.
    if @team.ta_hiring_needs.exists? && !TaHiringNeed.columns_hash['team_id']&.null
      flash[:error] = 'Cannot delete team with hiring history until the latest plugin migration is applied.'
      redirect_to admin_ta_teams_path
      return
    end

    if @team.destroy
      flash[:notice] = l(:notice_successful_delete)
    else
      flash[:error] = @team.errors.full_messages.presence&.join(', ') || 'Failed to delete team.'
    end
    redirect_to admin_ta_teams_path
  rescue ActiveRecord::NotNullViolation
    flash[:error] = 'Team deletion failed because hiring history preservation requires the latest plugin migration.'
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

  private

  def find_team
    @team = TaTeam.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def build_member_history_groups
    memberships = TaTeamMembership.includes(:user, :team).references(:user)
                                  .order('users.firstname ASC, users.lastname ASC, ta_team_memberships.start_date DESC, ta_team_memberships.created_at DESC')

    memberships.group_by(&:user).map do |user, user_memberships|
      active_memberships = user_memberships.select(&:active?)

      {
        user: user,
        memberships: user_memberships,
        active_team_count: active_memberships.count,
        has_active_lead_role: active_memberships.any?(&:lead?),
        last_updated_on: user_memberships.map { |membership| membership.updated_at || membership.created_at }.compact.max
      }
    end
  end
end
