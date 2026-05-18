class AdminTaTeamsController < ApplicationController
  layout 'admin'
  menu_item :team_analytics_configuration
  self.main_menu = false

  before_action :require_admin
  before_action :find_team, only: [:show, :edit, :update, :destroy]
  skip_before_action :require_admin, only: [:payload]
  before_action :authenticate_payload_request, only: [:payload]

  helper :ta_teams

  def index
    @all_teams = TaTeam.ordered_by_name.to_a
    @active_main_tab = params[:main_tab].presence || 'structure'
    @active_sidebar_tab = params[:sidebar_tab].presence || 'members'
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

  def payload
    limit, offset = payload_pagination
    teams_scope = TaTeam.ordered_by_name
    total_teams = teams_scope.count
    paginated_teams = teams_scope.offset(offset).limit(limit).to_a

    memberships_for_teams = if paginated_teams.any?
                              TaTeamMembership.where(team_id: paginated_teams.map(&:id))
                                              .order(:team_id, :user_id, :start_date, :id)
                                              .to_a
                            else
                              []
                            end
    memberships_by_team = memberships_for_teams.group_by(&:team_id)

    members_scope = TaTeamMembership.select(:user_id).distinct.order(:user_id)
    total_members = members_scope.count
    paginated_member_ids = members_scope.offset(offset).limit(limit).pluck(:user_id)

    users_by_id = User.where(id: paginated_member_ids).index_by(&:id)
    memberships_for_members = if paginated_member_ids.any?
                                TaTeamMembership.where(user_id: paginated_member_ids)
                                                .order(:user_id, :team_id, :start_date, :id)
                                                .to_a
                              else
                                []
                              end
    memberships_by_user = memberships_for_members.group_by(&:user_id)

    render json: {
      data: {
        teams: paginated_teams.map { |team| serialize_team_payload(team, memberships_by_team[team.id] || []) },
        members: paginated_member_ids.map { |user_id| serialize_member_payload(user_id, users_by_id[user_id], memberships_by_user[user_id] || []) }
      },
      pagination: {
        limit: limit,
        offset: offset,
        totalTeams: total_teams,
        totalMembers: total_members
      }
    }
  end

  private

  def authenticate_payload_request
    api_key = params[:api_key] || request.headers['X-Redmine-API-Key']

    if api_key.blank?
      render json: { error: 'API key is required' }, status: :unauthorized
      return
    end

    user = User.find_by(api_token: api_key)
    if user.blank? || !user.admin?
      render json: { error: 'Invalid API key or insufficient permissions' }, status: :forbidden
      return
    end

    User.current = user
  end

  def payload_pagination
    requested_limit = params[:limit].to_i
    requested_offset = params[:offset].to_i
    limit = requested_limit.positive? ? [requested_limit, 500].min : 100
    offset = requested_offset.positive? ? requested_offset : 0

    [limit, offset]
  end

  def serialize_team_payload(team, memberships)
    lead_member_ids = memberships.select(&:lead?).map { |membership| member_api_id(membership.user_id) }.uniq
    member_ids = memberships.map { |membership| member_api_id(membership.user_id) }.uniq

    {
      id: team_api_id(team.id),
      name: team.name,
      parentTeamId: team.parent_team_id.present? ? team_api_id(team.parent_team_id) : nil,
      leadMemberIds: lead_member_ids,
      memberIds: member_ids,
      metadata: serialize_record_metadata(team.attributes, 'ta_teams')
    }
  end

  def serialize_member_payload(user_id, user, memberships)
    {
      id: member_api_id(user_id),
      name: user.present? ? user.name : "User ##{user_id}",
      email: user&.mail,
      status: member_status(user),
      metadata: {
        sourceTable: 'ta_team_memberships',
        memberships: memberships.map { |membership| serialize_record_metadata(membership.attributes, 'ta_team_memberships') }
      }
    }
  end

  def serialize_record_metadata(attributes, table_name)
    normalized = attributes.each_with_object({}) do |(key, value), hash|
      hash[camelize_lower(key)] = serialize_metadata_value(value)
    end

    normalized.merge('sourceTable' => table_name)
  end

  def serialize_metadata_value(value)
    case value
    when Time, DateTime
      value.utc.iso8601
    when Date
      value.iso8601
    when Array
      value.map { |item| serialize_metadata_value(item) }
    when Hash
      value.each_with_object({}) { |(key, nested_value), hash| hash[camelize_lower(key.to_s)] = serialize_metadata_value(nested_value) }
    else
      value
    end
  end

  def member_status(user)
    return 'UNKNOWN' unless user

    case user.status
    when User::STATUS_ACTIVE
      'ACTIVE'
    when User::STATUS_REGISTERED
      'REGISTERED'
    when User::STATUS_LOCKED
      'LOCKED'
    else
      user.status.to_s.upcase
    end
  end

  def team_api_id(id)
    "team_#{id}"
  end

  def member_api_id(id)
    "member_#{id}"
  end

  def camelize_lower(value)
    parts = value.to_s.split('_')
    [parts.first, *parts[1..].map(&:capitalize)].join
  end

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
