class TeamAnalyticsController < ApplicationController

  before_action :require_login
  before_action :set_date_range, except: [:get_tree_data]
  before_action :set_grouping, except: [:get_tree_data]
  helper :time_analytics
  helper :ta_teams

  TABLEAU10_COLORS = [
    '#4E79A7', '#F28E2B', '#E15759', '#76B7B2', '#59A14F',
    '#EDC948', '#B07AA1', '#FF9DA7', '#9C755F', '#BAB0AC'
  ].freeze
  TEAM_OVERVIEW_ROW = Struct.new(:period, :member_count, :hours, :average, :support_hours, :effective_time_percentage, :effective_time_available, :raw_period, :holiday)

  def index
    # Super users can access all teams; team leads can access led teams + descendants
    @teams = User.current.accessible_team_dashboard_teams.to_a
    return render_403 unless @teams.any?

    @selected_team = select_accessible_team(@teams)
    
    Rails.logger.info "Team Analytics: Selected team: #{@selected_team&.name}, Date range: #{@from} to #{@to}"
    
    @view_mode = params[:view_mode] || 'members'
    @member_dashboard_params = build_member_dashboard_params
    @member_dashboard_query = @member_dashboard_params.to_query
    
    excluded_ids = TaTeamSetting.excluded_user_ids_for_range(@from, @to)

    # Temporary, session-only exclusions toggled from the Members summary table.
    # Not persisted — a refresh (no param) re-activates everyone.
    @temp_excluded_ids = Array(params[:temp_excluded_ids]).map(&:to_i).reject(&:zero?).uniq

    # Get all team members including sub-team members (bubble up from child teams)
    @team_members = @selected_team.hierarchical_members(@from, @to).to_a

    @member_ids = @team_members.map(&:user_id).uniq

    # Filter out permanently and temporarily excluded users
    @active_member_ids = @member_ids - (excluded_ids | @temp_excluded_ids)
    @team_size = @active_member_ids.count
    
    # Get sub-teams for dashboard display
    @sub_teams = @selected_team.child_teams.ordered_by_name
    
    Rails.logger.info "Team Analytics: Team members: #{@member_ids.count}, Active members: #{@active_member_ids.count}, Excluded: #{excluded_ids.count}, Sub-teams: #{@sub_teams.count}"
    
    @time_entries = team_time_entries_scope(@team_members, @from, @to)

    # Drop temporarily-excluded members from every aggregate (Total Hours, Max/Min,
    # Time Overview, member pivot, donut) before any aggregation runs.
    @time_entries = @time_entries.where.not(user_id: @temp_excluded_ids) if @time_entries && @temp_excluded_ids.any?

    @time_entries = @time_entries.includes(:user, :project, :issue, :activity)
                                 .order('time_entries.spent_on DESC, time_entries.created_on DESC') if @time_entries

    # If no members or conditions, return empty relation
    @time_entries ||= TimeEntry.none

    # Hours for temporarily-excluded members, used to still render their (struck-through)
    # rows in the Members summary table without counting them in any aggregate.
    @temp_excluded_members = build_temp_excluded_members
    
    Rails.logger.info "Team Analytics: Auto-discovered projects from member time logs"
    
    # Calculate team statistics
    @total_hours = @time_entries.sum(:hours)
    @entry_count = @time_entries.count
    @active_days_count = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(@from, @to)
    @team_leave_days = calculate_team_leave_days_for_period(@from, @to)

    # "Show Active Days" toggle (daily only): hide weekend/holiday days from the Trend chart and
    # Time Overview table. The checker is a pre-fetched O(1) lambda over the date range.
    @hide_holidays = params[:hide_holidays].to_s == '1'
    @period_working_day_checker = RedmineTimeAnalytics::WorkingDaysCalculator.working_day_checker(@from, @to)

    Rails.logger.info "Team Analytics: Found #{@entry_count} time entries, Total hours: #{@total_hours}"
    
    # Calculate summary statistics based on grouping
    case @grouping
    when 'daily'
      @max_period_hours, _ = calculate_max_daily_hours
      @min_period_hours, _ = calculate_min_daily_hours
    when 'weekly'
      @max_period_hours = calculate_max_weekly_hours
      @min_period_hours = calculate_min_weekly_hours
    when 'monthly'
      @max_period_hours = calculate_max_monthly_hours
      @min_period_hours = calculate_min_monthly_hours
    else
      # Default to weekly if invalid grouping
      @max_period_hours = calculate_max_weekly_hours
      @min_period_hours = calculate_min_weekly_hours
    end
    
    @limit = params[:per_page].present? ? params[:per_page].to_i : 25
    @offset = params[:page].present? ? (params[:page].to_i - 1) * @limit : 0

    # Time Overview pagination (separate from detailed tables)
    @overview_limit = 6
    @overview_page = params[:overview_page].to_i > 0 ? params[:overview_page].to_i : 1
    @overview_offset = (@overview_page - 1) * @overview_limit
    
    # Generate Time Overview data with team member count
    @time_overview_data = generate_team_time_overview_data(@time_entries, @grouping)
    apply_effective_time_to_overview_data!
    @overview_total_pages = (@time_overview_data.count.to_f / @overview_limit).ceil
    
    # Handle view-specific data preparation
    if @view_mode == 'time_entries'
      # Time Overview: Group by selected period (daily/weekly/monthly/yearly)
      # Show Date, Team Member Count, Hours
      @entry_count = @time_overview_data.count
      @paginated_entries = @time_overview_data.slice(@offset, @limit)
      
      # Generate chart data
      chart_type = normalize_team_chart_type(params[:chart_type], 'line')
      @chart_data = generate_team_chart_data(@time_entries, @grouping, chart_type)
      
      Rails.logger.info "Team Analytics: Chart data generated, length: #{@chart_data&.length}, type: #{chart_type}"
      
    elsif @view_mode == 'activity'
      # Activity view - Generate pivot table for Activity × Time Period matrix
      @activity_pivot_data = generate_activity_pivot_table(@time_entries, @grouping)
      # Detailed/Grouped tables show most-recent-first; @activity_pivot_data itself stays in
      # chronological order below since generate_activity_pivot_chart_data (Trend/Stacked charts)
      # and regroup_activity_pivot both read straight from it.
      @time_periods = @activity_pivot_data[:periods].reverse
      @display_raw_periods = @activity_pivot_data[:raw_periods].reverse
      @activities = @activity_pivot_data[:activities]
      @matrix_data = @activity_pivot_data[:matrix]
      @period_totals = @activity_pivot_data[:period_totals]
      @activity_totals = @activity_pivot_data[:activity_totals]
      @grand_total = @activity_pivot_data[:grand_total]

      # For pagination in detailed view, count actual periods with data
      @entry_count = @time_periods.count
      @paginated_periods = @time_periods.slice(@offset, @limit) || []

      # Track activity view state for chart generation
      @activity_view_state = params[:activity_view_state] || 'detailed'

      # Grouped tab: regroup the already-computed pivot data by the admin's Activity Groups.
      # Computed unconditionally (not gated on @activity_view_state) since Summary/Detailed/Grouped
      # are all rendered server-side and toggled client-side.
      # All defined activities (not just ones with logged hours in the current range), so the
      # "Customize groups" popup lets you place a brand-new activity into a group even before
      # anyone has logged time against it.
      group_view = TaActivityGroup.grouped_activity_view_data(@activity_pivot_data)
      @all_activities = group_view[:all_activities]
      @activity_groups = group_view[:groups]
      @activity_group_assignments = group_view[:assignments]
      @activity_group_pivot_data = group_view[:pivot_data]
      @activity_group_colors = group_view[:colors]

      # Generate chart data
      chart_type = normalize_team_chart_type(params[:chart_type], 'line')
      @chart_data = generate_activity_pivot_chart_data(@activity_pivot_data, chart_type, @activity_view_state)
      
      Rails.logger.info "Team Analytics: Activity pivot data generated, activities: #{@activities.count}, periods: #{@time_periods.count}"
      
    elsif @view_mode == 'project'
      # Project view - Generate pivot table for Project × Time Period matrix
      @project_pivot_data = generate_project_pivot_table(@time_entries, @grouping)
      # Detailed table shows most-recent-first; @project_pivot_data itself stays chronological
      # since generate_project_pivot_chart_data (Trend/Stacked charts) reads straight from it.
      @time_periods = @project_pivot_data[:periods].reverse
      @display_raw_periods = @project_pivot_data[:raw_periods].reverse
      @projects = @project_pivot_data[:projects]
      @matrix_data = @project_pivot_data[:matrix]
      @period_totals = @project_pivot_data[:period_totals]
      @project_totals = @project_pivot_data[:project_totals]
      @grand_total = @project_pivot_data[:grand_total]

      # For pagination in detailed view, count actual periods with data
      @entry_count = @time_periods.count
      @paginated_periods = @time_periods.slice(@offset, @limit) || []

      # Track project view state for chart generation
      @project_view_state = params[:project_view_state] || 'detailed'
      
      # Generate chart data
      chart_type = normalize_team_chart_type(params[:chart_type], 'line')
      @chart_data = generate_project_pivot_chart_data(@project_pivot_data, chart_type, @project_view_state)
      
      Rails.logger.info "Team Analytics: Project pivot data generated, projects: #{@projects.count}, periods: #{@time_periods.count}"
      
    elsif @view_mode == 'members'
      # Members view - Generate pivot table for Member × Time Period matrix
      @member_pivot_data = generate_member_pivot_table(@time_entries, @grouping)
      # Detailed table shows most-recent-first; @member_pivot_data itself stays chronological
      # since generate_member_pivot_chart_data (Trend/Stacked charts) reads straight from it.
      @time_periods = @member_pivot_data[:periods].reverse
      @display_raw_periods = @member_pivot_data[:raw_periods].reverse
      @members = @member_pivot_data[:members]
      @matrix_data = @member_pivot_data[:matrix]
      @period_totals = @member_pivot_data[:period_totals]
      @member_totals = @member_pivot_data[:member_totals]
      @grand_total = @member_pivot_data[:grand_total]

      # Logged Days / Active Days per member for the Summary view (replaces the hours-share
      # percentage badge there; the donut chart still shows the percentage breakdown).
      # Active Days = Working Days - Leave Days (unchanged).
      member_leave_days = TaLeaveRecord.total_leave_days_for_users(user_ids: @member_ids, from_date: @from, to_date: @to)
      @member_active_days = @member_ids.each_with_object({}) do |user_id, hash|
        hash[user_id] = [@active_days_count - member_leave_days[user_id].to_f, 0].max.round(2)
      end

      # Logged Days = distinct days within the period with at least one time log (SUM(hours) > 0),
      # counted from the already-filtered @time_entries scope (active projects, exclusions applied).
      # reorder(nil)/unscope(:includes) strip the eager-load and ORDER BY carried over from
      # @time_entries - Postgres rejects an ORDER BY column that isn't grouped or aggregated.
      @member_logged_days = @time_entries.unscope(:includes).reorder(nil)
                                          .group(:user_id, :spent_on)
                                          .having('SUM(time_entries.hours) > 0')
                                          .pluck(:user_id, :spent_on)
                                          .each_with_object(Hash.new(0)) { |(user_id, _date), hash| hash[user_id] += 1 }

      # For pagination in detailed view, count actual periods with data
      @entry_count = @time_periods.count
      @paginated_periods = @time_periods.slice(@offset, @limit) || []

      # Track member view state for chart generation.
      # Default to 'summary' when all members are excluded — that is the only view with re-include toggles.
      @member_view_state = params[:member_view_state] ||
                           (@members.empty? && @temp_excluded_members.any? ? 'summary' : 'detailed')

      # Monthly-avg table (Members tab) — only relevant with monthly grouping.
      @member_monthly_avg = @grouping == 'monthly' ? generate_member_monthly_avg_table(@time_entries, @from, @to) : nil

      # Generate chart data
      chart_type = normalize_team_chart_type(params[:chart_type], 'line')
      @chart_data = generate_member_pivot_chart_data(@member_pivot_data, chart_type, @member_view_state)
      
      Rails.logger.info "Team Analytics: Member pivot data generated, members: #{@members.count}, periods: #{@time_periods.count}"
      
    end
    
    @total_pages = (@entry_count.to_f / @limit).ceil

    respond_to do |format|
      format.html { render 'team_analytics/index' }
      format.json { 
        chart_data_hash = JSON.parse(@chart_data)
        render json: { 
          chart_data: chart_data_hash, 
          total_hours: @total_hours,
           chart_type: normalize_team_chart_type(params[:chart_type], 'line')
         } 
      }
    end
  end

  def export_csv
    @teams = User.current.accessible_team_dashboard_teams.to_a
    return render_403 unless @teams.any?

    @selected_team = select_accessible_team(@teams)
    
    @view_mode = params[:view_mode] || 'time_entries'
    
    excluded_ids = TaTeamSetting.excluded_user_ids_for_range(@from, @to)
    
    # Include all team members including sub-team members (bubble up from child teams)
    @team_members = @selected_team.hierarchical_members(@from, @to).to_a
    
    @member_ids = @team_members.map(&:user_id)
    @active_member_ids = @member_ids - excluded_ids
    
    @time_entries = team_time_entries_scope(@team_members, @from, @to)
    
    @time_entries = @time_entries.includes(:user, :project, :issue, :activity)
                                 .order('time_entries.spent_on DESC') if @time_entries
    
    # If no members or conditions, return empty relation
    @time_entries ||= TimeEntry.none

    # Generate CSV based on view mode
    csv_data = export_team_time_entries_to_csv(@time_entries, @selected_team)
    filename = "team_analytics_#{@selected_team.name.parameterize}_#{@from}_#{@to}.csv"
    
    send_data csv_data, 
              filename: filename,
              type: 'text/csv'
  end

  # API endpoint for tree view data
  def get_tree_data
    root_teams = User.current.team_dashboard_root_teams.to_a
    return render json: { error: 'Unauthorized' }, status: 403 unless root_teams.any?

    # Date range from params or use defaults
    from_date = parse_custom_date(params[:from]) || (Date.today - 7.days)
    to_date = parse_custom_date(params[:to]) || Date.today

    # Get excluded user IDs for the requested tree range
    excluded_ids = TaTeamSetting.excluded_user_ids_for_range(from_date, to_date)
    
    # Build hierarchical tree structure
    tree_nodes = []
    
    root_teams.each do |team|
      team_node, _subtree_user_ids = build_team_node(team, excluded_ids, from_date, to_date)
      tree_nodes << team_node
    end

    render json: tree_nodes
  end

  # API endpoint for period-specific team member details (Team Size modal)
  def get_period_team_members
    team_id = params[:team_id]
    period_start = params[:period_start].to_date rescue nil
    grouping = params[:grouping] || 'weekly'
    temp_excluded_ids = Array(params[:temp_excluded_ids]).map(&:to_i).reject(&:zero?).to_set

    return render json: { error: 'Missing parameters' }, status: 400 unless team_id && period_start

    team = TaTeam.find_by(id: team_id)
    return render json: { error: 'Team not found' }, status: 404 unless team

    period_end = case grouping
                 when 'daily'   then period_start
                 when 'monthly' then period_start.end_of_month
                 else                period_start.end_of_week(:monday)
                 end

    period_label = helpers.format_period_for_table(period_start, grouping, period_start, period_end)

    # Permanently-excluded users are dropped entirely; temp-excluded are kept but flagged.
    perm_excluded_ids = TaTeamSetting.excluded_user_ids_for_range(period_start, period_end)
    build_members = lambda do |memberships|
      memberships
        .reject { |m| perm_excluded_ids.include?(m.user_id) }
        .filter_map { |m| next unless m.user; { name: m.user.name, temp_excluded: temp_excluded_ids.include?(m.user_id), locked: m.user.locked? } }
        .sort_by { |m| [m[:temp_excluded] ? 1 : 0, m[:name]] }
    end

    if team.child_teams.any?
      groups = []

      direct = build_members.call(team.active_members(period_start, period_end))
      groups << { team_name: team.name, members: direct } if direct.any?

      team.all_descendants.each do |sub_team|
        sub = build_members.call(sub_team.active_members(period_start, period_end))
        groups << { team_name: sub_team.name, members: sub } if sub.any?
      end

      render json: { team_name: team.name, period_label: period_label, grouped: true, groups: groups }
    else
      members = build_members.call(team.active_members(period_start, period_end))
      render json: { team_name: team.name, period_label: period_label, grouped: false, members: members }
    end
  end

  # Lazy-loaded second-level breakdown for the Members view: each member's logged time split by
  # Issue, Activity, and Project. Reuses the exact same team scope/exclusions as `index` so the
  # cards stay consistent with the summary table above. All three groupings are returned at once
  # so the client can switch between them without re-fetching.
  def member_breakdown
    teams = User.current.accessible_team_dashboard_teams.to_a
    return render json: { error: 'Unauthorized' }, status: 403 unless teams.any?

    team = select_accessible_team(teams)
    return render json: { members: [] } unless team

    team_members = team.hierarchical_members(@from, @to).to_a
    permitted = params.permit(temp_excluded_ids: [])
    temp_excluded_ids = Array(permitted[:temp_excluded_ids]).map(&:to_i).reject(&:zero?).uniq

    scope = team_time_entries_scope(team_members, @from, @to)
    scope = scope.where.not(user_id: temp_excluded_ids) if temp_excluded_ids.any?

    # One grouped SUM per dimension — no per-member queries.
    issue_sums    = scope.group(:user_id, :issue_id).sum(:hours)
    activity_sums = scope.group(:user_id, :activity_id).sum(:hours)
    project_sums  = scope.group(:user_id, :project_id).sum(:hours)

    issues = Issue.where(id: issue_sums.keys.filter_map { |(_, id)| id }.uniq)
                  .includes(:tracker).index_by(&:id)
    activity_names = Enumeration.where(id: activity_sums.keys.filter_map { |(_, id)| id }.uniq)
                               .pluck(:id, :name).to_h
    project_names = Project.where(id: project_sums.keys.filter_map { |(_, id)| id }.uniq)
                          .pluck(:id, :name).to_h

    # Single SQL SUM per user rather than re-summing the per-issue sums above in Ruby, so this
    # total matches the Detailed table/donut chart total for the same member exactly.
    user_totals = scope.group(:user_id).sum(:hours)
    users = User.where(id: user_totals.keys).index_by(&:id)

    # Pre-group all three dimensions by user_id to avoid O(N×M) scanning in build_breakdown_items.
    issue_by_user    = group_sums_by_user(issue_sums)
    activity_by_user = group_sums_by_user(activity_sums)
    project_by_user  = group_sums_by_user(project_sums)

    sorted_user_ids = user_totals.keys.sort_by { |uid| [-user_totals[uid], users[uid]&.name.to_s] }

    members = sorted_user_ids.filter_map do |uid|
      user = users[uid]
      next unless user

      total = user_totals[uid]
      {
        id: uid,
        name: user.name,
        locked: user.locked?,
        total_hours: total,
        groupings: {
          issue: build_breakdown_items(issue_by_user[uid] || {}, total) do |id|
            issue = id && issues[id]
            next ["##{id}", "##{id}"] if id && issue.nil?
            issue ? ["##{issue.id} #{issue.subject}", "##{issue.id}"] : [l(:label_ta_no_issue), l(:label_ta_no_issue)]
          end,
          activity: build_breakdown_items(activity_by_user[uid] || {}, total) do |id|
            name = id && activity_names[id]
            name ? [name, name] : [l(:label_ta_no_activity), l(:label_ta_no_activity)]
          end,
          project: build_breakdown_items(project_by_user[uid] || {}, total) do |id|
            name = id && project_names[id]
            name ? [name, name] : [l(:label_ta_no_project), l(:label_ta_no_project)]
          end
        }
      }
    end

    render json: { members: members }
  end

  # Recursively build team node with sub-teams and members.
  # Returns [node_hash, subtree_user_ids] where subtree_user_ids is the Set of distinct
  # current active members across this team and all its descendants (team composition).
  def build_team_node(team, excluded_ids, from_date, to_date)
    # Get direct members for this team only (currently active only)
    memberships = TaTeamMembership.where(team: team)
                                 .where('start_date <= ? AND (end_date IS NULL OR end_date >= ?)', Date.today, Date.today)
                                 .includes(:user)

    # Build team node
    team_node = {
      id: "team_#{team.id}",
      text: team.name,
      icon: "icon icon-group",
      state: { opened: false },
      a_attr: {
        'data-node-type': 'team',
        'data-team-id': team.id
      },
      data: {
        team_id: team.id
      },
      children: []
    }

    # Distinct active members across this team's whole subtree (includes excluded users —
    # this is the full team composition, unlike the analytics "Team Size" which drops excluded).
    subtree_user_ids = Set.new

    # Add sub-teams first (hierarchical)
    team.child_teams.ordered_by_name.each do |child_team|
      child_node, child_user_ids = build_team_node(child_team, excluded_ids, from_date, to_date)
      team_node[:children] << child_node
      subtree_user_ids.merge(child_user_ids)
    end

    # Add direct members after sub-teams
    memberships.each do |membership|
      user = membership.user
      next unless user

      is_excluded = excluded_ids.include?(membership.user_id)
      subtree_user_ids << membership.user_id

      # Member node
      member_node = {
        id: "member_#{team.id}_#{user.id}",
        text: user.name,
        icon: "icon icon-user",
        state: { opened: false },
        a_attr: {
          'data-node-type': 'member',
          'data-user-id': user.id,
          'data-excluded': is_excluded ? 'true' : 'false'
        },
        data: {
          user_id: user.id,
          excluded: is_excluded
        }
      }
      
      team_node[:children] << member_node
    end

    # Append the total team-composition count as a styled badge after the team name.
    # jsTree renders node text as HTML, so escape the name and inject the badge span.
    team_node[:text] =
      "#{ERB::Util.html_escape(team.name)}" \
      "<span class=\"team-tree-count-badge\">#{subtree_user_ids.size}</span>"

    [team_node, subtree_user_ids]
  end

  private

  # Turns a pre-grouped {group_id => hours} hash for a single user into a sorted, colored list.
  # The block maps a group_id to [label, short_label].
  def build_breakdown_items(user_sums, total)
    user_sums.filter_map { |gid, hours| [gid, hours.to_f] if hours.to_f > 0 }
             .sort_by { |_, hours| -hours }
             .each_with_index.map do |(gid, hours), index|
               label, short_label = yield(gid)
               {
                 label: label,
                 short_label: short_label,
                 hours: hours,
                 percentage: total > 0 ? (hours / total * 100).round(1) : 0,
                 color: TABLEAU10_COLORS[index % TABLEAU10_COLORS.size]
               }
             end
  end

  # Groups a {[user_id, group_id] => hours} hash into {user_id => {group_id => hours}}.
  def group_sums_by_user(sums)
    sums.each_with_object(Hash.new { |h, k| h[k] = {} }) do |((uid, gid), hours), h|
      h[uid][gid] = hours.to_f
    end
  end

  def select_accessible_team(teams)
    default_team = default_accessible_team(teams)
    return default_team if params[:team_id].blank?

    requested_team = TaTeam.find_by(id: params[:team_id])
    teams.include?(requested_team) ? requested_team : default_team
  end

  def default_accessible_team(teams)
    return nil if teams.empty?
    return teams.first unless User.current.super_user_for_team_analytics?

    # For super users, default to the first root team in database order
    root_team = TaTeam.root_teams.first
    teams.include?(root_team) ? root_team : teams.first
  end

  def team_time_entries_scope(team_members, from_date, to_date)
    return TimeEntry.none if team_members.blank?

    member_ids = team_members.map(&:user_id).uniq
    member_conditions = team_members.map do |membership|
      member_from_date = [membership.start_date, from_date].max
      member_to_date = membership.end_date ? [membership.end_date, to_date].min : to_date
      "(time_entries.user_id = #{membership.user_id} AND time_entries.spent_on >= '#{member_from_date}' AND time_entries.spent_on <= '#{member_to_date}')"
    end.uniq.join(' OR ')

    scope = TimeEntry.joins(:project)
                     .where(user_id: member_ids)
                     .where(spent_on: from_date..to_date)
                     .where(projects: { status: Project::STATUS_ACTIVE })

    scope = scope.where("(#{member_conditions})") if member_conditions.present?
    scope.where(TaTeamSetting.exclusion_time_entry_condition)
  end

  def parse_custom_date(value)
    return nil if value.blank?

    Date.strptime(value, '%m/%d/%Y')
  rescue ArgumentError
    Date.parse(value)
  end

  def set_date_range
    @filter = params[:filter].presence || 'this_month'

    case @filter
    when 'this_month'
      # Month-to-date: from the 1st of the current month through today (not the month end).
      @from = Date.current.beginning_of_month
      @to = Date.current
    when 'last_month'
      @from = (Date.current - 1.month).beginning_of_month
      @to = (Date.current - 1.month).end_of_month
    when 'last_3_months'
      # Last 3 complete months (excluding current month)
      # Example: If today is Jan 2026, show Oct, Nov, Dec 2025
      @from = (Date.current - 3.months).beginning_of_month
      @to = (Date.current - 1.month).end_of_month
    when 'custom'
      @from = parse_custom_date(params[:from]) || Date.current.beginning_of_month
      @to = parse_custom_date(params[:to]) || Date.current.end_of_month
    else
      # Default to this month (month-to-date)
      @filter = 'this_month'
      @from = Date.current.beginning_of_month
      @to = Date.current
    end
  rescue ArgumentError
    # Handle invalid date format
    @filter = 'this_month'
    @from = Date.current.beginning_of_month
    @to = Date.current
  end

  def set_grouping
    # Default to weekly grouping for team dashboard
    @grouping = params[:grouping].presence || 'weekly'
    @grouping = 'weekly' unless %w[daily weekly monthly].include?(@grouping)
  end

  def build_member_dashboard_params
    base_params = { grouping: @grouping }

    # Individual dashboard does not support last_month/last_3_months directly.
    # Keep date boundaries identical by mapping those to custom with explicit dates.
    if @filter == 'this_month'
      base_params.merge(filter: 'this_month')
    else
      base_params.merge(
        filter: 'custom',
        from: @from.strftime('%Y-%m-%d'),
        to: @to.strftime('%Y-%m-%d')
      )
    end
  end

  # Daily grouping calculations
  def calculate_max_daily_hours
    daily_totals = @time_entries.reorder(nil).group(:spent_on).sum(:hours)
    return [0, nil] if daily_totals.empty?
    max_entry = daily_totals.max_by { |_, hours| hours }
    [max_entry[1], max_entry[0]]
  end

  def calculate_min_daily_hours
    daily_totals = @time_entries.reorder(nil).group(:spent_on).sum(:hours)
    return [0, nil] if daily_totals.empty?
    min_entry = daily_totals.min_by { |_, hours| hours }
    [min_entry[1], min_entry[0]]
  end

  # Weekly grouping calculations
  def calculate_max_weekly_hours
    weekly_totals = get_weekly_totals(@time_entries)
    return 0 if weekly_totals.empty?
    weekly_totals.values.max
  end

  def calculate_min_weekly_hours
    weekly_totals = get_weekly_totals(@time_entries)
    return 0 if weekly_totals.empty?
    weekly_totals.values.min
  end

  def get_weekly_totals(entries)
    sql_bucket_hours_totals(entries, 'weekly')
  end

  # Monthly grouping calculations
  def calculate_max_monthly_hours
    monthly_totals = get_monthly_totals(@time_entries)
    return 0 if monthly_totals.empty?
    monthly_totals.values.max
  end

  def calculate_min_monthly_hours
    monthly_totals = get_monthly_totals(@time_entries)
    return 0 if monthly_totals.empty?
    monthly_totals.values.min
  end

  def get_monthly_totals(entries)
    sql_bucket_hours_totals(entries, 'monthly')
  end

  # SQL-computed hours total for each week/month bucket present in `entries`, keyed the same
  # way the old Ruby-loop bucketing was (Date for weekly, [year, month] Array for monthly).
  #
  # `time_entries.hours` is a SQL float column, so manually accumulating `entry.hours` across
  # hundreds of loaded records in Ruby drifts from the DB's own SUM() for the same rows (each
  # value round-trips through decimal<->float text parsing once per row instead of being
  # accumulated once, internally, by the database). Running one SUM(:hours) query per bucket
  # keeps every total on the same computation path as `@total_hours` (`entries.sum(:hours)`),
  # so e.g. a "Max Month" bucket that spans the entire filtered range matches Total Hours exactly.
  def sql_bucket_hours_totals(entries, unit)
    return entries.reorder(nil).group(:spent_on).sum(:hours) if unit == 'daily'

    dates = entries.reorder(nil).distinct.pluck(:spent_on)
    return {} if dates.empty?

    bucket_ranges = dates.each_with_object({}) do |date, ranges|
      if unit == 'monthly'
        month_start = Date.new(date.year, date.month, 1)
        key = [date.year, date.month]
        ranges[key] ||= [month_start, month_start.end_of_month]
      else
        week_start = date.beginning_of_week(:monday)
        ranges[week_start] ||= [week_start, week_start + 6.days]
      end
    end

    bucket_ranges.each_with_object({}) do |(key, (bucket_start, bucket_end)), totals|
      totals[key] = entries.reorder(nil).where(spent_on: bucket_start..bucket_end).sum(:hours)
    end
  end

  # Period-bucket boundaries for the Members/Activity/Project pivot tables, keyed the same way
  # get_activity_period_key keys their periods (Date for daily/weekly, Date.new(y,m,1) for
  # monthly) — distinct from sql_bucket_hours_totals's [year, month] Array keying, which the
  # Time Overview table / Max-Min-Month cards depend on and which this deliberately leaves alone.
  def pivot_period_bucket_ranges(entries, grouping)
    dates = entries.reorder(nil).distinct.pluck(:spent_on)
    return {} if dates.empty?

    dates.each_with_object({}) do |date, ranges|
      key = get_activity_period_key(date, grouping)
      range_end = grouping == 'monthly' ? key.end_of_month : key + 6.days
      ranges[key] ||= [key, range_end]
    end
  end

  # SQL SUM(:hours) per pivot-table period bucket — see pivot_period_bucket_ranges. Replaces
  # manually accumulating `entry.hours` (a SQL float column) row-by-row in Ruby, which drifts
  # from the database's own SUM() over the same rows (the root cause of the Detailed
  # table/donut chart not matching Total Hours).
  def pivot_bucket_hours_totals(entries, grouping)
    return entries.reorder(nil).group(:spent_on).sum(:hours) if grouping == 'daily'

    pivot_period_bucket_ranges(entries, grouping).each_with_object({}) do |(key, (bucket_start, bucket_end)), totals|
      totals[key] = entries.reorder(nil).where(spent_on: bucket_start..bucket_end).sum(:hours)
    end
  end

  # Same bucketing as pivot_bucket_hours_totals, further grouped by `group_column` (:user_id,
  # :activity_id, :project_id) — returns { period_key => { group_value => hours } }, each value
  # a single SQL SUM rather than a Ruby-loop accumulation.
  def pivot_bucket_category_totals(entries, grouping, group_column)
    if grouping == 'daily'
      return entries.reorder(nil).group(:spent_on, group_column).sum(:hours)
                    .each_with_object({}) { |((date, gval), hrs), acc| (acc[date] ||= {})[gval] = hrs }
    end

    pivot_period_bucket_ranges(entries, grouping).each_with_object({}) do |(key, (bucket_start, bucket_end)), totals|
      totals[key] = entries.reorder(nil).where(spent_on: bucket_start..bucket_end).group(group_column).sum(:hours)
    end
  end

  # Generate team time overview data with member count per period
  def generate_team_time_overview_data(entries, grouping)
    data = case grouping
           when 'daily'
             entries.reorder(nil).group(:spent_on).sum(:hours)
           when 'monthly'
             sql_bucket_hours_totals(entries, 'monthly')
           else
             # weekly, and the invalid-grouping fallback (both bucket by week)
             sql_bucket_hours_totals(entries, 'weekly')
           end

    # Fill missing periods to show unlogged days/weeks/months as 0.00h
    if grouping == 'daily'
      data = fill_missing_working_days_team(data, @from, @to)
    elsif grouping == 'weekly'
      data = fill_missing_weeks_team(data, @from, @to)
    elsif grouping == 'monthly'
      data = fill_missing_months_team(data, @from, @to)
    end
    
    # Sort by period key in DESCENDING order (newest first, like Individual Dashboard)
    sorted_data = data.sort_by { |key, _| key }.reverse

    # "Show Active Days": drop weekend/holiday days entirely (even logged ones).
    sorted_data = sorted_data.reject { |key, _| ta_team_holiday_date?(key) } if grouping == 'daily' && @hide_holidays

      # Return structured data with period, team_size (not member_count), hours, and average
    sorted_data.map do |period, hours|
      # Convert period key to appropriate format for the helper
      period_for_display = if period.is_a?(Array)
                             Date.new(period[0], period[1], 1)
                           else
                             period.to_date
                           end
      
      period_label = helpers.format_period_for_table(period_for_display, grouping, @from, @to)
      # Calculate actual team size for this specific period based on membership dates
      team_size = calculate_team_size_for_period(period_for_display, grouping)
      
      # Calculate average: Total Hours / (Team Size * Active Working Days)
      average = calculate_period_average(period_for_display, grouping, hours, team_size)

      is_holiday = grouping == 'daily' && ta_team_holiday_date?(period_for_display)
      TEAM_OVERVIEW_ROW.new(period_label, team_size, hours, average, nil, nil, false, period_for_display.to_s, is_holiday)
    end
  end

  def apply_effective_time_to_overview_data!
    @show_effective_time_column = false
    @effective_time_error_message = nil
    return if @time_overview_data.blank?
    # Team-level opt-out: skip support time entirely (direct + inherited) for this team.
    return if @selected_team.hide_support_time?

    # Get direct external assignments
    external_assignments = @selected_team.ta_team_projects.where(source_type: 'external').active_between(@from, @to).to_a
    
    # Get inherited external projects from child teams
    inherited_external = @selected_team.inherited_projects(@from, @to).select { |p| p.external_source? }
    
    # Combine all external assignments
    all_external_assignments = external_assignments + inherited_external
    
    return if all_external_assignments.blank?

    @show_effective_time_column = true
    config = TaTeamSetting.support_redmine_settings
    service = RedmineTimeAnalytics::ExternalRedmineTimeService.new(
      base_url: config[:base_url],
      api_key: config[:api_key]
    )

    result = service.calculate_hours_by_period(
      assignments: all_external_assignments,
      from: @from,
      to: @to,
      grouping: @grouping
    )

    if result.errors.any?
      @effective_time_error_message = result.errors.uniq.join('; ')
      @time_overview_data = @time_overview_data.map do |row|
        TEAM_OVERVIEW_ROW.new(row.period, row.member_count, row.hours, row.average, nil, nil, false, row.raw_period, row.holiday)
      end
      return
    end

    raw_periods = period_keys_for_overview_data(@grouping)
    @time_overview_data = @time_overview_data.each_with_index.map do |row, index|
      raw_key = raw_periods[index]
      support_hours = result.hours_by_period[raw_key].to_f
      internal_hours = row.hours.to_f

      effective_percentage = if internal_hours.zero?
                               nil
                             else
                               ((support_hours / internal_hours) * 100.0).round(2)
                             end

      TEAM_OVERVIEW_ROW.new(row.period, row.member_count, row.hours, row.average, support_hours, effective_percentage, !effective_percentage.nil?, row.raw_period, row.holiday)
    end
  rescue StandardError => e
    @show_effective_time_column = true
    @effective_time_error_message = e.message
    @time_overview_data = @time_overview_data.map do |row|
      TEAM_OVERVIEW_ROW.new(row.period, row.member_count, row.hours, row.average, nil, nil, false, row.raw_period, row.holiday)
    end
  end

  def period_keys_for_overview_data(grouping)
    grouped = {}
    @time_entries.each do |entry|
      key = case grouping
            when 'daily'
              entry.spent_on
            when 'monthly'
              [entry.spent_on.year, entry.spent_on.month]
            else
              entry.spent_on.beginning_of_week(:monday)
            end
      grouped[key] ||= 0
      grouped[key] += entry.hours
    end

    grouped = fill_missing_working_days_team(grouped, @from, @to) if grouping == 'daily'
    grouped = fill_missing_weeks_team(grouped, @from, @to) if grouping == 'weekly'
    grouped = fill_missing_months_team(grouped, @from, @to) if grouping == 'monthly'
    sorted = grouped.sort_by { |key, _| key }.reverse
    # Keep aligned with generate_team_time_overview_data so Effective Time columns map correctly.
    sorted = sorted.reject { |key, _| ta_team_holiday_date?(key) } if grouping == 'daily' && @hide_holidays
    sorted.map(&:first)
  end

  # Generate chart data for team view
  def generate_team_chart_data(entries, grouping, chart_type)
    if chart_type == 'bar'
      return generate_time_entries_stacked_chart_data(entries, grouping)
    end

    # SQL SUM(:hours) per bucket instead of a manual Ruby-loop accumulation over `entry.hours`
    # (a SQL float column) — keeps the Trend chart's points on the same computation path as
    # Total Hours / Max-Min Month, which already use sql_bucket_hours_totals.
    grouped_data = sql_bucket_hours_totals(entries, grouping)

    # Fill missing periods for proper date range handling (show unlogged periods as 0.00)
    if grouping == 'daily'
      grouped_data = fill_missing_working_days_team(grouped_data, @from, @to)
    elsif grouping == 'weekly'
      grouped_data = fill_missing_weeks_team(grouped_data, @from, @to)
    elsif grouping == 'monthly'
      grouped_data = fill_missing_months_team(grouped_data, @from, @to)
    end
    
    # Sort by period key in ASCENDING order (oldest first for chart, like Individual Dashboard)
    sorted_data = grouped_data.sort_by { |key, _| key }

    # "Show Active Days": drop weekend/holiday points entirely (even logged ones).
    sorted_data = sorted_data.reject { |key, _| ta_team_holiday_date?(key) } if grouping == 'daily' && @hide_holidays

    raw_keys = sorted_data.map(&:first)
    values = sorted_data.map { |_, hours| hours.round(2) }

    boundaries = []
    if grouping == 'daily'
      axis = helpers.build_daily_chart_axis(raw_keys)
      labels = axis[:labels]
      boundaries = axis[:boundaries]
    else
      labels = case grouping
        when 'monthly' then helpers.build_monthly_chart_labels(raw_keys)
        when 'weekly' then helpers.build_weekly_chart_axis(raw_keys)
        else sorted_data.map { |period, _| format_chart_label_for_team(period, grouping) }
      end
      boundaries = helpers.build_period_boundaries(raw_keys, grouping)
    end

    # Flag weekend/holiday points (daily only) so they render amber.
    holiday_flags = grouping == 'daily' ? raw_keys.map { |key| ta_team_holiday_date?(key) } : raw_keys.map { false }
    generate_line_chart_from_data(labels, values, raw_keys, grouping, holiday_flags, boundaries)
  end

  def generate_time_entries_stacked_chart_data(entries, grouping)
    return empty_chart_data('bar') if entries.blank?

    # SQL SUM(:hours) per (period, activity) bucket instead of accumulating `entry.hours` (a SQL
    # float column) row-by-row in Ruby — same fix as the Members/Activity/Project pivot tables.
    hours_by_period = pivot_bucket_category_totals(entries, grouping, :activity_id)
    return empty_chart_data('bar') if hours_by_period.empty?

    activity_ids = hours_by_period.values.flat_map(&:keys).uniq.compact
    activity_names_by_id = Enumeration.where(id: activity_ids).pluck(:id, :name).to_h
    name_for = ->(id) { activity_names_by_id[id] || 'No Activity' }

    category_breakdown = {}
    hours_by_period.each do |period_key, hours_by_activity_id|
      category_breakdown[period_key] = {}
      hours_by_activity_id.each do |activity_id, hrs|
        name = name_for.call(activity_id)
        category_breakdown[period_key][name] = (category_breakdown[period_key][name] || 0) + hrs
      end
    end

    activity_totals = entries.reorder(nil).group(:activity_id).sum(:hours)
                              .each_with_object(Hash.new(0.0)) { |(id, hrs), h| h[name_for.call(id)] += hrs }
    activities = activity_totals.sort_by { |_, total| -total }.map(&:first)

    generate_stacked_bar_chart_from_matrix(category_breakdown.keys, activities, category_breakdown, grouping)
  end

  # Export team time entries to CSV
  def export_team_time_entries_to_csv(entries, team)
    require 'csv'
    
    CSV.generate(headers: true) do |csv|
      csv << ['Team', 'Date', 'Member', 'Project', 'Issue', 'Activity', 'Hours', 'Comments']
      
      entries.each do |entry|
        csv << [
          team.name,
          entry.spent_on.strftime('%Y-%m-%d'),
          entry.user.name,
          entry.project.name,
          entry.issue&.subject || 'N/A',
          entry.activity&.name || 'N/A',
          entry.hours,
          entry.comments || ''
        ]
      end
    end
  end

  # Generate Activity × Time Period pivot table (reused from individual dashboard logic)
  def generate_activity_pivot_table(time_entries, grouping)
    Rails.logger.info "Generating activity pivot table for grouping: #{grouping}, entries count: #{time_entries.count}"
    
    # Period totals and per-(period, activity) cells are computed via SQL SUM — not by
    # accumulating `entry.hours` (a SQL float column) row-by-row in Ruby — so every number here
    # lines up exactly with Total Hours / Max-Min Month and the donut chart.
    period_totals = pivot_bucket_hours_totals(time_entries, grouping)
    hours_by_period = pivot_bucket_category_totals(time_entries, grouping, :activity_id)

    periods = period_totals.keys.sort
    activity_ids_with_entries = hours_by_period.values.flat_map(&:keys).uniq.compact
    activity_names_by_id = Enumeration.where(id: activity_ids_with_entries).pluck(:id, :name).to_h
    name_for = ->(id) { activity_names_by_id[id] || 'No Activity' }

    # Matrix keyed by activity name for lookup (matches existing view code)
    matrix_data = {}
    periods.each do |period|
      matrix_data[period] = {}
      (hours_by_period[period] || {}).each do |activity_id, hrs|
        name = name_for.call(activity_id)
        matrix_data[period][name] = (matrix_data[period][name] || 0) + hrs
      end
    end

    # Activity totals + grand total via a single SQL SUM query each (not summed from the
    # per-bucket hashes above).
    sql_activity_totals = time_entries.reorder(nil).group(:activity_id).sum(:hours)
    activity_totals = Hash.new(0.0)
    activity_ids = {}
    sql_activity_totals.each do |activity_id, hours|
      name = name_for.call(activity_id)
      activity_totals[name] += hours
      activity_ids[name] ||= activity_id
    end
    grand_total = time_entries.reorder(nil).sum(:hours)

    # Keep activity order consistent across stacked chart and donut chart colors
    activities = activity_totals.keys.sort_by { |activity| -(activity_totals[activity] || 0) }

    {
      periods: periods.map { |p| format_activity_period_display(p, grouping) },
      activities: activities,
      matrix: matrix_data,
      period_totals: period_totals,
      activity_totals: activity_totals,
      grand_total: grand_total,
      raw_periods: periods, # Keep original keys for matrix lookup
      activity_ids: activity_ids
    }
  end

  # Get period key for activity grouping (matches Time Entries format)
  def get_activity_period_key(date, grouping)
    case grouping
    when 'daily'
      date
    when 'weekly'
      # Use Monday-based week start to match Time Entries format
      days_since_monday = (date.wday - 1) % 7
      start_of_week = date - days_since_monday
      start_of_week
    when 'monthly'
      # Use first day of month as key
      Date.new(date.year, date.month, 1)
    else
      # Default to weekly - Monday of week
      days_since_monday = (date.wday - 1) % 7
      date - days_since_monday
    end
  end

  # Format period display for activity tables
  def format_activity_period_display(period_key, grouping)
    case grouping
    when 'daily'
      helpers.format_period_for_table(period_key, grouping, @from, @to)
    when 'weekly'
      # Reuse the same logic as Time Entries section for consistency
      helpers.format_period_for_table(period_key, grouping, @from, @to)
    when 'monthly'
      month_date = if period_key.is_a?(Array)
        Date.new(period_key[0], period_key[1], 1)
      else
        period_key.to_date
      end
      month_date.strftime('%B %Y') # "October 2025"
    else
      # Default to weekly
      helpers.format_period_for_table(period_key, grouping, @from, @to)
    end
  end

  # Generate chart data for activity pivot table
  def generate_activity_pivot_chart_data(pivot_data, chart_type, activity_view_state = 'detailed')
    case chart_type
    when 'bar'
      generate_stacked_bar_chart_from_matrix(pivot_data[:raw_periods], pivot_data[:activities], pivot_data[:matrix], @grouping)
    else
      generate_pivot_line_chart(pivot_data[:raw_periods], pivot_data[:period_totals])
    end
  end

  # Generate bar chart from data arrays
  def generate_bar_chart_from_data(labels, data_values, raw_keys = nil, grouping = nil)
    # Generate detailed tooltip labels for weekly grouping
    tooltip_labels = if raw_keys && grouping == 'weekly'
      raw_keys.map { |key| helpers.format_period_for_tooltip(key, grouping, @from, @to) }
    else
      labels
    end
    
    chart_data = {
      labels: labels,
      datasets: [{
        label: 'Hours',
        data: data_values,
        backgroundColor: '#36a2eb',
        borderColor: '#ffffff',
        borderWidth: 1,
        tooltipLabels: tooltip_labels,
        formattedHours: data_values.map { |hours| helpers.format_hours(hours) }
      }]
    }

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      legend: {
        display: false
      },
      tooltips: {
        mode: 'index',
        intersect: false,
        backgroundColor: 'rgba(0, 0, 0, 0.8)',
        padding: 12,
        titleFontSize: 14,
        titleFontStyle: 'bold',
        bodyFontSize: 13,
        cornerRadius: 8
      },
      scales: {
        yAxes: [{
          ticks: {
            beginAtZero: true,
            fontSize: 11
          },
          scaleLabel: {
            display: true,
            labelString: 'Hours',
            fontSize: 12,
            fontStyle: 'bold'
          }
        }],
        xAxes: [{
          scaleLabel: {
            display: true,
            labelString: grouping ? helpers.grouping_label(grouping) : '',
            fontSize: 12,
            fontStyle: 'bold'
          },
          ticks: {
            maxRotation: 45,
            minRotation: 45,
            fontSize: 11
          }
        }]
      }
    }

    {
      type: 'bar',
      data: chart_data,
      options: chart_options
    }.to_json.html_safe
  end

  # Generate line chart from data arrays
  def generate_line_chart_from_data(labels, data_values, raw_keys = nil, grouping = nil, holiday_flags = nil, boundaries = nil)
    # Generate detailed tooltip labels for weekly grouping; full descriptive dates for daily and
    # monthly (decoupled from the short axis labels used for daily/monthly grouping's
    # data.labels).
    tooltip_labels = if raw_keys && grouping == 'weekly'
      raw_keys.map { |key| helpers.format_period_for_tooltip(key, grouping, @from, @to) }
    elsif raw_keys && grouping == 'daily'
      raw_keys.map { |key| helpers.format_chart_label(key) }
    elsif raw_keys && grouping == 'monthly'
      raw_keys.map { |key| helpers.format_period_for_table(key, grouping, @from, @to) }
    else
      labels
    end

    primary_color = '#36a2eb'

    formatted_hours = data_values.map { |hours| helpers.format_hours(hours) }
    single_point = data_values.length == 1

    # Weekend/holiday points render amber (#f59e0b); regular working days stay dark blue.
    holiday_flags ||= data_values.map { false }
    point_colors = holiday_flags.map { |holiday| holiday ? '#f59e0b' : '#1d4ed8' }

    # Center a lone data point by padding a blank slot on each side, so it renders
    # in the middle of the chart instead of hugging the left edge.
    if single_point
      labels          = ['', labels.first, '']
      tooltip_labels  = ['', tooltip_labels.first, '']
      formatted_hours = ['', formatted_hours.first, '']
      data_values     = [nil, data_values.first, nil]
      holiday_flags   = [false, holiday_flags.first, false]
      point_colors    = ['#1d4ed8', point_colors.first, '#1d4ed8']
    end

    chart_data = {
      labels: labels,
      datasets: [{
        label: 'Hours',
        data: data_values,
        borderColor: primary_color,
        backgroundColor: color_with_alpha(primary_color, 0.15),
        fill: true,
        tension: 0.2,
        borderWidth: 2,
        # Solid dark dots so points stay clearly visible with one or many data points.
        pointRadius: single_point ? 6 : 4,
        pointHoverRadius: single_point ? 8 : 6,
        pointBackgroundColor: point_colors,
        pointBorderColor: point_colors,
        pointBorderWidth: 1,
        holidayFlags: holiday_flags,
        tooltipLabels: tooltip_labels,
        formattedHours: formatted_hours
      }]
    }

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      legend: {
        display: true,
        position: 'bottom',
        labels: {
          usePointStyle: true,
          padding: 15,
          fontSize: 12
        }
      },
      tooltips: {
        mode: 'index',
        intersect: false,
        backgroundColor: 'rgba(0, 0, 0, 0.8)',
        padding: 12,
        titleFontSize: 14,
        titleFontStyle: 'bold',
        bodyFontSize: 13,
        cornerRadius: 8
      },
      scales: {
        yAxes: [{
          ticks: {
            beginAtZero: true,
            fontSize: 11
          },
          scaleLabel: {
            display: true,
            labelString: 'Hours',
            fontSize: 12,
            fontStyle: 'bold'
          }
        }],
        xAxes: [{
          scaleLabel: {
            display: true,
            labelString: grouping ? helpers.grouping_label(grouping) : '',
            fontSize: 12,
            fontStyle: 'bold'
          },
          ticks: {
            maxRotation: %w[daily weekly monthly].include?(grouping) ? 0 : 45,
            minRotation: %w[daily weekly monthly].include?(grouping) ? 0 : 45,
            autoSkip: !%w[daily weekly monthly].include?(grouping),
            fontSize: 11
          }
        }]
      }
    }

    chart_options[:monthYearSeparator] = { boundaries: boundaries } if boundaries.present?

    {
      type: 'line',
      data: chart_data,
      options: chart_options
    }.to_json.html_safe
  end

  # Generate Project × Time Period pivot table
  def generate_project_pivot_table(time_entries, grouping)
    Rails.logger.info "Generating project pivot table for grouping: #{grouping}, entries count: #{time_entries.count}"
    
    # Get personal project IDs if configured
    personal_project_ids = @selected_team.personal_project_ids

    # Period totals and per-(period, project) cells are computed via SQL SUM — not by
    # accumulating `entry.hours` (a SQL float column) row-by-row in Ruby — so every number here
    # lines up exactly with Total Hours / Max-Min Month and the donut chart.
    period_totals = pivot_bucket_hours_totals(time_entries, grouping)
    hours_by_period = pivot_bucket_category_totals(time_entries, grouping, :project_id)

    periods = period_totals.keys.sort
    project_ids_with_entries = hours_by_period.values.flat_map(&:keys).uniq.compact
    project_names_by_id = Project.where(id: project_ids_with_entries).pluck(:id, :name).to_h
    name_for = lambda do |id|
      return 'No Project' if id.nil?
      return 'Personal Projects' if personal_project_ids.include?(id)
      project_names_by_id[id] || 'No Project'
    end

    # Matrix keyed by project name for lookup (matches existing view code). Multiple personal
    # sub-projects collapse into a single "Personal Projects" cell, so this += combines at most a
    # handful of already-SQL-summed values per period — nowhere near the per-entry Ruby-loop
    # accumulation this replaces.
    matrix_data = {}
    periods.each do |period|
      matrix_data[period] = {}
      (hours_by_period[period] || {}).each do |project_id, hrs|
        name = name_for.call(project_id)
        matrix_data[period][name] = (matrix_data[period][name] || 0) + hrs
      end
    end

    # Project totals + grand total via a single SQL SUM query each.
    sql_project_totals = time_entries.reorder(nil).group(:project_id).sum(:hours)
    project_totals = Hash.new(0.0)
    sql_project_totals.each do |project_id, hours|
      project_totals[name_for.call(project_id)] += hours
    end
    grand_total = time_entries.reorder(nil).sum(:hours)

    # Sort projects by total hours descending (largest to smallest)
    projects = project_totals.keys.sort_by { |project| -project_totals[project] }

    {
      periods: periods.map { |p| format_activity_period_display(p, grouping) },
      projects: projects,
      matrix: matrix_data,
      period_totals: period_totals,
      project_totals: project_totals,
      grand_total: grand_total,
      raw_periods: periods # Keep original keys for matrix lookup
    }
  end

  # Generate chart data for project pivot table
  def generate_project_pivot_chart_data(pivot_data, chart_type, project_view_state = 'detailed')
    case chart_type
    when 'bar'
      generate_stacked_bar_chart_from_matrix(pivot_data[:raw_periods], pivot_data[:projects], pivot_data[:matrix], @grouping)
    else
      generate_pivot_line_chart(pivot_data[:raw_periods], pivot_data[:period_totals])
    end
  end

  # Generate Member × Time Period pivot table
  def generate_member_pivot_table(time_entries, grouping)
    Rails.logger.info "Generating member pivot table for grouping: #{grouping}, entries count: #{time_entries.count}"
    
    # Period totals and per-(period, member) cells are computed via SQL SUM — not by
    # accumulating `entry.hours` (a SQL float column) row-by-row in Ruby — so every number here
    # lines up exactly with Total Hours / Max-Min Month and the donut chart.
    period_totals = pivot_bucket_hours_totals(time_entries, grouping)
    hours_by_period = pivot_bucket_category_totals(time_entries, grouping, :user_id)

    periods = period_totals.keys.sort
    user_ids_with_entries = hours_by_period.values.flat_map(&:keys).uniq
    users_by_id = User.where(id: user_ids_with_entries).index_by(&:id)
    # `locked` flags a member whose account is locked but who logged time in this range -
    # e.g. left the company mid-period. Surfaced as a badge on the Summary cards + Team
    # Members popup (see ta_locked_badge / taLockedBadgeHtml) so it isn't mistaken for a
    # currently-active member.
    members_with_entries = user_ids_with_entries.map do |uid|
      user = users_by_id[uid]
      { id: uid, name: user.name, locked: user.locked? }
    end

    # Include all active team members so those with 0 logged hours still appear
    active_members = @team_members
      .select { |m| @active_member_ids.include?(m.user_id) }
      .map { |m| { id: m.user_id, name: m.user.name, locked: m.user.locked? } }

    members_unsorted = (active_members + members_with_entries).uniq { |m| m[:id] }

    # Matrix keyed by member name for lookup (matches existing view code)
    matrix_data = {}
    periods.each do |period|
      matrix_data[period] = {}
      members_unsorted.each do |member_data|
        hrs = hours_by_period.dig(period, member_data[:id])
        matrix_data[period][member_data[:name]] = hrs if hrs
      end
    end

    # Calculate member totals via SQL SUM to avoid accumulated float errors.
    # reorder(nil) strips any ORDER BY from the scope so MySQL ONLY_FULL_GROUP_BY is satisfied.
    # Keyed by member id (not name) so two members who happen to share a display name can
    # never collide into a single total.
    sql_user_totals = time_entries.reorder(nil).group(:user_id).sum(:hours)
    member_totals = {}
    members_unsorted.each do |member_data|
      member_totals[member_data[:id]] = sql_user_totals[member_data[:id]] || 0
    end

    # Sort members by total hours descending (largest to smallest), then by name
    members = members_unsorted.sort_by { |member_data| [-member_totals[member_data[:id]], member_data[:name]] }

    grand_total = time_entries.reorder(nil).sum(:hours)
    
    {
      periods: periods.map { |p| format_activity_period_display(p, grouping) },
      members: members, # Array of {id:, name:} hashes
      matrix: matrix_data, # Still keyed by member name for lookup
      period_totals: period_totals,
      member_totals: member_totals, # Keyed by member id
      grand_total: grand_total,
      raw_periods: periods # Keep original keys for matrix lookup
    }
  end

  # Per-member daily-average hours for each month in the period (Members tab "Monthly avg"
  # table, only used with monthly grouping). Reuses the same daily-average definition as the
  # individual dashboard: hours / (working days - leave days), clamped at 0 active days.
  def generate_member_monthly_avg_table(time_entries, from, to)
    members = @team_members
                .select { |m| @active_member_ids.include?(m.user_id) }
                .map { |m| { id: m.user_id, name: m.user&.name } }
                .reject { |m| m[:name].blank? }
                .uniq { |m| m[:id] }
    member_ids = members.map { |m| m[:id] }

    # Month buckets within the period, each clamped to the period bounds.
    months = []
    cursor = from.beginning_of_month
    while cursor <= to
      months << {
        key:   cursor.strftime('%Y-%m'),
        label: cursor.strftime('%b %Y'),
        start: [cursor, from].max,
        end:   [cursor.end_of_month, to].min
      }
      cursor = cursor.next_month
    end

    # Hours per member per month, bucketed in Ruby to stay DB-agnostic.
    hours = Hash.new(0.0)
    time_entries.each do |entry|
      next unless entry.user_id && entry.spent_on
      hours[[entry.user_id, entry.spent_on.strftime('%Y-%m')]] += entry.hours
    end

    # Working days + per-member leave days for each month and for the whole period.
    working_days = {}
    leave_by_month = {}
    months.each do |mo|
      working_days[mo[:key]]   = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(mo[:start], mo[:end])
      leave_by_month[mo[:key]] = TaLeaveRecord.total_leave_days_for_users(user_ids: member_ids, from_date: mo[:start], to_date: mo[:end])
    end
    total_working_days = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(from, to)
    total_leave        = TaLeaveRecord.total_leave_days_for_users(user_ids: member_ids, from_date: from, to_date: to)

    daily_avg = lambda { |hrs, active_days| active_days > 0 ? (hrs / active_days).round(2) : 0.0 }

    rows = members.map do |m|
      monthly = {}
      total_hours = 0.0
      months.each do |mo|
        hrs = hours[[m[:id], mo[:key]]]
        total_hours += hrs
        active_days = [working_days[mo[:key]] - (leave_by_month[mo[:key]][m[:id]] || 0.0), 0].max
        monthly[mo[:key]] = daily_avg.call(hrs, active_days)
      end
      overall_active = [total_working_days - (total_leave[m[:id]] || 0.0), 0].max
      { id: m[:id], name: m[:name], monthly: monthly, overall: daily_avg.call(total_hours, overall_active) }
    end

    # Default order: highest overall daily average first (matches the design). The client
    # re-sorts in memory when a column header is clicked.
    rows.sort_by! { |r| [-r[:overall], r[:name].to_s.downcase] }

    { months: months.map { |mo| { key: mo[:key], label: mo[:label] } }, rows: rows }
  end

  # Generate chart data for member pivot table
  def generate_member_pivot_chart_data(pivot_data, chart_type, member_view_state = 'detailed')
    case chart_type
    when 'bar'
      member_names = pivot_data[:members].map { |member| member[:name] }
      generate_stacked_bar_chart_from_matrix(pivot_data[:raw_periods], member_names, pivot_data[:matrix], @grouping)
    else
      generate_pivot_line_chart(pivot_data[:raw_periods], pivot_data[:period_totals])
    end
  end

  # Shared line-chart builder for the Members/Activity/Project pivot views. Applies the
  # weekend/holiday amber flags and the "Show Active Days" filter (daily grouping only) so all
  # trend charts behave like the My Time page.
  def generate_pivot_line_chart(raw_periods, period_totals)
    periods = raw_periods.dup
    periods = periods.reject { |period| ta_team_holiday_date?(period) } if @grouping == 'daily' && @hide_holidays

    boundaries = []
    if @grouping == 'daily'
      axis = helpers.build_daily_chart_axis(periods)
      labels = axis[:labels]
      boundaries = axis[:boundaries]
    else
      labels = case @grouping
        when 'monthly' then helpers.build_monthly_chart_labels(periods)
        when 'weekly' then helpers.build_weekly_chart_axis(periods)
        else periods.map { |period| format_activity_period_display(period, @grouping) }
      end
      boundaries = helpers.build_period_boundaries(periods, @grouping)
    end

    data_values = periods.map { |period| period_totals[period] || 0 }
    holiday_flags = @grouping == 'daily' ? periods.map { |period| ta_team_holiday_date?(period) } : periods.map { false }
    generate_line_chart_from_data(labels, data_values, periods, @grouping, holiday_flags, boundaries)
  end

  def generate_stacked_bar_chart_from_matrix(period_keys, categories, matrix_data, grouping)
    return empty_chart_data('bar') if period_keys.blank? || categories.blank?

    sorted_periods = period_keys.uniq.sort
    sorted_periods = if grouping == 'daily'
      fill_missing_working_days_team(sorted_periods.each_with_object({}) { |period_key, hash| hash[period_key] = 0 }, @from, @to).keys.sort
    elsif grouping == 'weekly'
      fill_missing_weeks_team(sorted_periods.each_with_object({}) { |period_key, hash| hash[period_key] = 0 }, @from, @to).keys.sort
    else
      fill_missing_months_team(sorted_periods.each_with_object({}) { |period_key, hash| hash[period_key] = 0 }, @from, @to).keys.sort
    end

    boundaries = []
    if grouping == 'daily'
      axis = helpers.build_daily_chart_axis(sorted_periods)
      formatted_labels = axis[:labels]
      boundaries = axis[:boundaries]
      tooltip_labels = sorted_periods.map { |key| helpers.format_chart_label(key) }
    else
      full_labels = sorted_periods.map { |key| format_activity_period_display(key, grouping) }
      formatted_labels = case grouping
        when 'monthly' then helpers.build_monthly_chart_labels(sorted_periods)
        when 'weekly' then helpers.build_weekly_chart_axis(sorted_periods)
        else full_labels
      end

      tooltip_labels = if grouping == 'weekly'
        sorted_periods.map { |key| helpers.format_period_for_tooltip(key, grouping, @from, @to) }
      else
        full_labels
      end

      boundaries = helpers.build_period_boundaries(sorted_periods, grouping)
    end

    datasets = categories.each_with_index.map do |category, index|
      data = sorted_periods.map { |period_key| matrix_data[period_key]&.[](category) || 0 }
      {
        label: category,
        data: data,
        backgroundColor: TABLEAU10_COLORS[index % TABLEAU10_COLORS.length],
        borderColor: '#ffffff',
        borderWidth: 1,
        hoverBorderColor: '#ffffff',
        maxBarThickness: 197,
        stack: 'stack0',
        tooltipLabels: tooltip_labels,
        formattedHours: data.map { |hours| helpers.format_hours(hours) }
      }
    end

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      legend: {
        display: false
      },
      tooltips: {
        mode: 'nearest',
        intersect: true,
        backgroundColor: 'rgba(0, 0, 0, 0.8)',
        padding: 12,
        titleFontSize: 14,
        titleFontStyle: 'bold',
        bodyFontSize: 13,
        cornerRadius: 8
      },
      scales: {
        xAxes: [{
          stacked: true,
          scaleLabel: {
            display: true,
            labelString: helpers.grouping_label(grouping),
            fontSize: 12,
            fontStyle: 'bold'
          },
          ticks: {
            maxRotation: %w[daily weekly monthly].include?(grouping) ? 0 : 45,
            minRotation: %w[daily weekly monthly].include?(grouping) ? 0 : 45,
            autoSkip: !%w[daily weekly monthly].include?(grouping),
            fontSize: 11
          }
        }],
        yAxes: [{
          stacked: true,
          ticks: {
            beginAtZero: true,
            fontSize: 11
          },
          scaleLabel: {
            display: true,
            labelString: 'Hours',
            fontSize: 12,
            fontStyle: 'bold'
          }
        }]
      },
      plugins: {
        colorschemes: {
          scheme: 'tableau.Tableau10'
        }
      }
    }

    chart_options[:monthYearSeparator] = { boundaries: boundaries } if boundaries.present?

    {
      type: 'bar',
      data: {
        labels: formatted_labels,
        datasets: datasets
      },
      options: chart_options
    }.to_json.html_safe
  end

  def empty_chart_data(chart_type)
    {
      empty: true,
      type: chart_type,
      data: {
        labels: [],
        datasets: []
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        legend: {
          display: false
        },
        tooltips: {
          enabled: false
        }
      }
    }.to_json.html_safe
  end

  def normalize_team_chart_type(chart_type, fallback = 'line')
    %w[line bar].include?(chart_type) ? chart_type : fallback
  end

  def tableau10_colors(count)
    return [] if count.to_i <= 0

    Array.new(count) { |i| TABLEAU10_COLORS[i % TABLEAU10_COLORS.length] }
  end

  def color_with_alpha(hex_color, alpha)
    hex = hex_color.to_s.delete('#')
    return hex_color if hex.length != 6

    r = hex[0..1].to_i(16)
    g = hex[2..3].to_i(16)
    b = hex[4..5].to_i(16)
    "rgba(#{r}, #{g}, #{b}, #{alpha})"
  end

  # Fill missing days for team dashboard (one entry per calendar date in range)
  # A team "non-working" day = weekend or admin Company Holiday (no per-user leave at team level).
  # Used both to flag a day amber and to hide it when the "Show Active Days" toggle is on.
  def ta_team_holiday_date?(date)
    date.is_a?(Date) && @period_working_day_checker && !@period_working_day_checker.call(date)
  end

  def fill_missing_working_days_team(grouped_data, from_date, to_date)
    result = {}

    (from_date..to_date).each do |date|
      # Include the date only when it's a working day, OR time was logged on it (even if it's a
      # weekend/holiday). Empty weekend/holiday days are dropped from chart + overview by default.
      if (@period_working_day_checker && @period_working_day_checker.call(date)) || grouped_data.key?(date)
        result[date] = grouped_data[date] || 0
      end
    end

    result
  end

  # Fill missing weeks for team dashboard (includes weeks overlapping with date range)
  def fill_missing_weeks_team(grouped_data, from_date, to_date)
    # Include weeks that overlap with the date range (like Individual Dashboard)
    # Find Monday of the week containing from_date
    days_since_monday = (from_date.wday - 1) % 7
    start_monday = from_date - days_since_monday
    
    # Find Monday of the week containing to_date
    days_since_monday_end = (to_date.wday - 1) % 7
    end_monday = to_date - days_since_monday_end
    
    result = {}
    current = start_monday
    
    while current <= end_monday
      result[current] = grouped_data[current] || 0
      current += 7.days
    end
    
    result
  end

  # Fill missing months for team dashboard
  def fill_missing_months_team(grouped_data, from_date, to_date)
    result = {}
    current = from_date.beginning_of_month
    sample_key = grouped_data.keys.first
    
    while current <= to_date
      month_key = sample_key.is_a?(Array) ? [current.year, current.month] : current
      result[month_key] = grouped_data[month_key] || 0
      current = current.next_month
    end
    
    result
  end

  # Calculate average for a period:
  # Team Active Days = (Working Days * Team Size) - Team Leave Days
  # Average = Hours / Team Active Days
  #
  # Working/leave days are clamped to the selected filter range (@from..@to), not the full
  # calendar week/month a period bucket belongs to — otherwise an in-progress period (e.g.
  # "This Month" month-to-date) would count days that haven't happened yet, deflating the average.
  def calculate_period_average(period_date, grouping, hours, team_size)
    return 0 if team_size.zero? || hours.zero?

    period_start, period_end = case grouping
                               when 'weekly'
                                 week_start = period_date.beginning_of_week(:monday)
                                 week_end = week_start + 6.days
                                 [week_start, week_end]
                               when 'monthly'
                                 month_start = period_date.beginning_of_month
                                 month_end = period_date.end_of_month
                                 [month_start, month_end]
                               else
                                 [period_date, period_date]
                               end

    clamped = RedmineTimeAnalytics::WorkingDaysCalculator.clamp_to_range(period_start, period_end, @from, @to)
    return 0 if clamped.nil?
    period_start, period_end = clamped

    working_days = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(period_start, period_end)
    return 0 if working_days.zero?

    leave_days = calculate_team_leave_days_for_period(period_start, period_end)
    team_active_days = (working_days * team_size) - leave_days
    return 0 if team_active_days <= 0

    (hours / team_active_days).round(2)
  end

  # Calculate team size for a specific period based on membership dates (not time logging)
  def calculate_team_size_for_period(period_date, grouping)
    # Determine period start and end dates based on grouping
    period_start, period_end = case grouping
                                when 'daily'
                                  [period_date, period_date]
                                when 'weekly'
                                  week_start = period_date.beginning_of_week(:monday)
                                  week_end = week_start + 6.days
                                  [week_start, week_end]
                                when 'monthly'
                                  month_start = period_date.beginning_of_month
                                  month_end = period_date.end_of_month
                                  [month_start, month_end]
                                else
                                  # Default to weekly
                                  week_start = period_date.beginning_of_week(:monday)
                                  week_end = week_start + 6.days
                                  [week_start, week_end]
                                end

    # Excluded users are still filtered by the period they overlap with
    excluded_ids = TaTeamSetting.excluded_user_ids_for_range(period_start, period_end) | Array(@temp_excluded_ids)

    # Count DISTINCT members active during this period (based on membership dates, not time
    # entries). A member holding multiple concurrent memberships (e.g. bubbled up from two
    # different sub-teams, like belonging to both "Automation" and "Manufacturing Automation")
    # must still only count once toward team size — grouping by user_id first, then counting a
    # user as active if ANY of their memberships overlaps the period, avoids double-counting.
    active_count = @team_members
      .reject { |membership| excluded_ids.include?(membership.user_id) }
      .select do |membership|
        start_date = membership.start_date
        end_date = membership.end_date

        # Member is active during period if:
        # - Their start_date is on or before the period ends (start_date <= period_end)
        # - AND their end_date is either NULL (still active) OR on or after the period starts (end_date >= period_start)
        start_date <= period_end && (end_date.nil? || end_date >= period_start)
      end
      .map(&:user_id)
      .uniq
      .count

    active_count
  end

  def calculate_team_leave_days_for_period(period_start, period_end)
    excluded_ids = TaTeamSetting.excluded_user_ids | Array(@temp_excluded_ids)
    seen_user_dates = {}
    total_leave_days = 0.0

    @team_members.each do |membership|
      next if excluded_ids.include?(membership.user_id)

      membership_start = [membership.start_date, period_start].max
      membership_end = membership.end_date ? [membership.end_date, period_end].min : period_end
      next if membership_end < membership_start

      TaLeaveRecord.confirmed.where(user_id: membership.user_id, leave_date: membership_start..membership_end).find_each do |record|
        next unless RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(record.leave_date)

        key = [record.user_id, record.leave_date]
        next if seen_user_dates[key]

        seen_user_dates[key] = true
        total_leave_days += record.leave_fraction.to_f
      end
    end

    total_leave_days
  end

  # Build the list of temporarily-excluded members (id/name/hours) so their rows can still
  # be shown in the Members summary table, struck-through, without affecting any aggregate.
  def build_temp_excluded_members
    return [] if @temp_excluded_ids.blank?

    # Permanent-excluded users are already filtered out by team_time_entries_scope;
    # here we deliberately keep the temp set so we can display their hours.
    hours_by_user = team_time_entries_scope(@team_members, @from, @to)
                      .where(user_id: @temp_excluded_ids)
                      .reorder(nil)
                      .group(:user_id)
                      .sum(:hours)

    names_by_user = @team_members.each_with_object({}) do |membership, acc|
      acc[membership.user_id] ||= membership.user&.name
    end

    @temp_excluded_ids.map do |user_id|
      next unless names_by_user.key?(user_id)

      { id: user_id, name: names_by_user[user_id], hours: hours_by_user[user_id] || 0 }
    end.compact
  end

  # Format chart label for team dashboard (proper week format: YYYY-WW)
  def format_chart_label_for_team(period, grouping)
    case grouping
    when 'daily'
      # Format as "Mon DD, YYYY" (matches Individual Dashboard daily chart labels)
      period.strftime('%b %d, %Y')
    when 'weekly'
      # Format as YYYY-WW (ISO week number)
      year = period.cwyear
      week = period.cweek
      "#{year}-#{week}"
    when 'monthly'
      # Format as "Month YYYY" (full month name like Individual Dashboard)
      Date.new(period[0], period[1], 1).strftime('%B %Y')
    else
      # Default to weekly
      year = period.cwyear
      week = period.cweek
      "#{year}-#{week}"
    end
  end
end
