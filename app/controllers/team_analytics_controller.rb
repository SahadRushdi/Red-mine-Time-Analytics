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
  TEAM_OVERVIEW_ROW = Struct.new(:period, :member_count, :hours, :average, :support_hours, :effective_time_percentage, :effective_time_available)

  def index
    # Super users can access all teams; team leads can access led teams + descendants
    @teams = User.current.accessible_team_dashboard_teams.to_a
    return render_403 unless @teams.any?

    @selected_team = select_accessible_team(@teams)
    
    Rails.logger.info "Team Analytics: Selected team: #{@selected_team&.name}, Date range: #{@from} to #{@to}"
    
    @view_mode = params[:view_mode] || 'members'
    @member_dashboard_params = build_member_dashboard_params
    @member_dashboard_query = @member_dashboard_params.to_query
    
    # Get excluded user IDs from settings
    excluded_ids = TaTeamSetting.excluded_user_ids
    
    # Get hierarchical team members (own + inherited from child teams)
    # This implements the "bubble up" logic where child team members appear in parent teams
    @team_members = @selected_team.hierarchical_members(@from, @to)
    
    @member_ids = @team_members.map(&:user_id).uniq
    
    # Filter out excluded users
    @active_member_ids = @member_ids - excluded_ids
    @team_size = @active_member_ids.count
    
    # Get sub-teams for dashboard display
    @sub_teams = @selected_team.child_teams.ordered_by_name
    
    Rails.logger.info "Team Analytics: Team members: #{@member_ids.count}, Active members: #{@active_member_ids.count}, Excluded: #{excluded_ids.count}, Sub-teams: #{@sub_teams.count}"
    
    # Get time entries for all active team members on ALL projects where they have logged time
    # Filter by member start_date and end_date within the selected date range
    # Build conditions to respect each member's start date and end date
    member_conditions = @team_members.map do |membership|
      member_from_date = [membership.start_date, @from].max
      member_to_date = membership.end_date ? [membership.end_date, @to].min : @to
      "(time_entries.user_id = #{membership.user_id} AND time_entries.spent_on >= '#{member_from_date}' AND time_entries.spent_on <= '#{member_to_date}')"
    end.uniq.join(' OR ')
    
    @time_entries = TimeEntry.joins(:project)
                             .where(user_id: @active_member_ids)
                             .where(spent_on: @from..@to)
                             .where(projects: { status: Project::STATUS_ACTIVE })
                             .where(member_conditions) if member_conditions.present?
    
    @time_entries = @time_entries.includes(:user, :project, :issue, :activity)
                                 .order('time_entries.spent_on DESC, time_entries.created_on DESC') if @time_entries
    
    # If no members or conditions, return empty relation
    @time_entries ||= TimeEntry.none
    
    Rails.logger.info "Team Analytics: Auto-discovered projects from member time logs"
    
    # Calculate team statistics
    @total_hours = @time_entries.sum(:hours)
    @entry_count = @time_entries.count
    @active_days_count = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(@from, @to)

    Rails.logger.info "Team Analytics: Found #{@entry_count} time entries, Total hours: #{@total_hours}"
    
    # Calculate summary statistics based on grouping
    case @grouping
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
      @time_periods = @activity_pivot_data[:periods]
      @activities = @activity_pivot_data[:activities]
      @matrix_data = @activity_pivot_data[:matrix]
      @period_totals = @activity_pivot_data[:period_totals]
      @activity_totals = @activity_pivot_data[:activity_totals]
      @grand_total = @activity_pivot_data[:grand_total]
      
      # For pagination, use time overview count to include periods with 0 hours
      @entry_count = @time_overview_data.count
      @paginated_periods = @time_periods.slice(@offset, @limit)
      
      # Track activity view state for chart generation
      @activity_view_state = params[:activity_view_state] || 'detailed'
      
      # Generate chart data
      chart_type = normalize_team_chart_type(params[:chart_type], 'line')
      @chart_data = generate_activity_pivot_chart_data(@activity_pivot_data, chart_type, @activity_view_state)
      
      Rails.logger.info "Team Analytics: Activity pivot data generated, activities: #{@activities.count}, periods: #{@time_periods.count}"
      
    elsif @view_mode == 'project'
      # Project view - Generate pivot table for Project × Time Period matrix
      @project_pivot_data = generate_project_pivot_table(@time_entries, @grouping)
      @time_periods = @project_pivot_data[:periods]
      @projects = @project_pivot_data[:projects]
      @matrix_data = @project_pivot_data[:matrix]
      @period_totals = @project_pivot_data[:period_totals]
      @project_totals = @project_pivot_data[:project_totals]
      @grand_total = @project_pivot_data[:grand_total]
      
      # For pagination, use time overview count to include periods with 0 hours
      @entry_count = @time_overview_data.count
      @paginated_periods = @time_periods.slice(@offset, @limit)
      
      # Track project view state for chart generation
      @project_view_state = params[:project_view_state] || 'detailed'
      
      # Generate chart data
      chart_type = normalize_team_chart_type(params[:chart_type], 'line')
      @chart_data = generate_project_pivot_chart_data(@project_pivot_data, chart_type, @project_view_state)
      
      Rails.logger.info "Team Analytics: Project pivot data generated, projects: #{@projects.count}, periods: #{@time_periods.count}"
      
    elsif @view_mode == 'members'
      # Members view - Generate pivot table for Member × Time Period matrix
      @member_pivot_data = generate_member_pivot_table(@time_entries, @grouping)
      @time_periods = @member_pivot_data[:periods]
      @members = @member_pivot_data[:members]
      @matrix_data = @member_pivot_data[:matrix]
      @period_totals = @member_pivot_data[:period_totals]
      @member_totals = @member_pivot_data[:member_totals]
      @grand_total = @member_pivot_data[:grand_total]
      
      # For pagination, use time overview count to include periods with 0 hours
      @entry_count = @time_overview_data.count
      @paginated_periods = @time_periods.slice(@offset, @limit)
      
      # Track member view state for chart generation
      @member_view_state = params[:member_view_state] || 'detailed'
      
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
    
    # Get excluded user IDs
    excluded_ids = TaTeamSetting.excluded_user_ids
    
    # Include selected team + descendants (same access model as dashboard)
    @team_members = @selected_team.hierarchical_members(@from, @to)
    
    @member_ids = @team_members.map(&:user_id)
    @active_member_ids = @member_ids - excluded_ids
    
    # Get time entries for all active team members on ALL projects where they have logged time
    # Filter by member start_date and end_date within the selected date range
    member_conditions = @team_members.map do |membership|
      member_from_date = [membership.start_date, @from].max
      member_to_date = membership.end_date ? [membership.end_date, @to].min : @to
      "(time_entries.user_id = #{membership.user_id} AND time_entries.spent_on >= '#{member_from_date}' AND time_entries.spent_on <= '#{member_to_date}')"
    end.join(' OR ')
    
    @time_entries = TimeEntry.joins(:project)
                             .where(user_id: @active_member_ids)
                             .where(spent_on: @from..@to)
                             .where(projects: { status: Project::STATUS_ACTIVE })
                             .where(member_conditions) if member_conditions.present?
    
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
    
    # Get excluded user IDs
    excluded_ids = TaTeamSetting.excluded_user_ids
    
    # Date range from params or use defaults
    from_date = parse_custom_date(params[:from]) || (Date.today - 7.days)
    to_date = parse_custom_date(params[:to]) || Date.today
    
    # Build hierarchical tree structure
    tree_nodes = []
    
    root_teams.each do |team|
      team_node = build_team_node(team, excluded_ids, from_date, to_date)
      tree_nodes << team_node
    end
    
    render json: tree_nodes
  end

  # Recursively build team node with sub-teams and members
  def build_team_node(team, excluded_ids, from_date, to_date)
    # Get direct members for this team only
    memberships = TaTeamMembership.where(team: team)
                                 .where('end_date IS NULL OR end_date >= ?', from_date)
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
    
    # Add sub-teams first (hierarchical)
    team.child_teams.ordered_by_name.each do |child_team|
      child_node = build_team_node(child_team, excluded_ids, from_date, to_date)
      team_node[:children] << child_node
    end
    
    # Add direct members after sub-teams
    memberships.each do |membership|
      next if excluded_ids.include?(membership.user_id)
      
      user = membership.user
      
      # Member node
      member_node = {
        id: "member_#{team.id}_#{user.id}",
        text: user.name,
        icon: "icon icon-user",
        state: { opened: false },
        a_attr: {
          'data-node-type': 'member',
          'data-user-id': user.id
        },
        data: {
          user_id: user.id
        }
      }
      
      team_node[:children] << member_node
    end
    
    team_node
  end

  private

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
      @from = Date.current.beginning_of_month
      @to = Date.current.end_of_month
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
      # Default to this month
      @filter = 'this_month'
      @from = Date.current.beginning_of_month
      @to = Date.current.end_of_month
    end
  rescue ArgumentError
    # Handle invalid date format
    @filter = 'this_month'
    @from = Date.current.beginning_of_month
    @to = Date.current.end_of_month
  end

  def set_grouping
    # Default to weekly grouping for team dashboard
    @grouping = params[:grouping].presence || 'weekly'
    @grouping = 'weekly' unless %w[weekly monthly].include?(@grouping)
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
    weekly_data = {}
    entries.each do |entry|
      week_start = entry.spent_on.beginning_of_week(:monday)
      weekly_data[week_start] ||= 0
      weekly_data[week_start] += entry.hours
    end
    weekly_data
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
    monthly_data = {}
    entries.each do |entry|
      month_key = [entry.spent_on.year, entry.spent_on.month]
      monthly_data[month_key] ||= 0
      monthly_data[month_key] += entry.hours
    end
    monthly_data
  end

  # Generate team time overview data with member count per period
  def generate_team_time_overview_data(entries, grouping)
    data = {}
    
    entries.each do |entry|
      period_key = case grouping
                   when 'weekly'
                     entry.spent_on.beginning_of_week(:monday)
                   when 'monthly'
                     [entry.spent_on.year, entry.spent_on.month]
                   else
                     # Default to weekly
                     entry.spent_on.beginning_of_week(:monday)
                   end
      
      data[period_key] ||= 0
      data[period_key] += entry.hours
    end
    
    # Fill missing periods to show unlogged weeks/months as 0.00h
    if grouping == 'weekly'
      data = fill_missing_weeks_team(data, @from, @to)
    elsif grouping == 'monthly'
      data = fill_missing_months_team(data, @from, @to)
    end
    
    # Sort by period key in DESCENDING order (newest first, like Individual Dashboard)
    sorted_data = data.sort_by { |key, _| key }.reverse
    
    # Return structured data with period, team_size (not member_count), hours, and average
    sorted_data.map do |period, hours|
      # Convert period key to appropriate format for the helper
      period_for_display = case grouping
                           when 'monthly'
                             if period.is_a?(Array)
                               Date.new(period[0], period[1], 1)
                             else
                               period.to_date
                             end
                           else
                             period
                           end
      
      period_label = helpers.format_period_for_table(period_for_display, grouping, @from, @to)
      # Calculate actual team size for this specific period based on membership dates
      team_size = calculate_team_size_for_period(period_for_display, grouping)
      
      # Calculate average: Total Hours / (Team Size * Active Working Days)
      average = calculate_period_average(period_for_display, grouping, hours, team_size)
      
      TEAM_OVERVIEW_ROW.new(period_label, team_size, hours, average, nil, nil, false)
    end
  end

  def apply_effective_time_to_overview_data!
    @show_effective_time_column = false
    @effective_time_error_message = nil
    return if @time_overview_data.blank?

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
        TEAM_OVERVIEW_ROW.new(row.period, row.member_count, row.hours, row.average, nil, nil, false)
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

      TEAM_OVERVIEW_ROW.new(row.period, row.member_count, row.hours, row.average, support_hours, effective_percentage, !effective_percentage.nil?)
    end
  rescue StandardError => e
    @show_effective_time_column = true
    @effective_time_error_message = e.message
    @time_overview_data = @time_overview_data.map do |row|
      TEAM_OVERVIEW_ROW.new(row.period, row.member_count, row.hours, row.average, nil, nil, false)
    end
  end

  def period_keys_for_overview_data(grouping)
    grouped = {}
    @time_entries.each do |entry|
      key = if grouping == 'monthly'
              [entry.spent_on.year, entry.spent_on.month]
            else
              entry.spent_on.beginning_of_week(:monday)
            end
      grouped[key] ||= 0
      grouped[key] += entry.hours
    end

    grouped = fill_missing_weeks_team(grouped, @from, @to) if grouping == 'weekly'
    grouped = fill_missing_months_team(grouped, @from, @to) if grouping == 'monthly'
    grouped.sort_by { |key, _| key }.reverse.map(&:first)
  end

  # Generate chart data for team view
  def generate_team_chart_data(entries, grouping, chart_type)
    if chart_type == 'bar'
      return generate_time_entries_stacked_chart_data(entries, grouping)
    end

    grouped_data = {}
    
    entries.each do |entry|
      period_key = case grouping
                   when 'weekly'
                     entry.spent_on.beginning_of_week(:monday)
                   when 'monthly'
                     [entry.spent_on.year, entry.spent_on.month]
                   else
                     # Default to weekly
                     entry.spent_on.beginning_of_week(:monday)
                   end
      
      grouped_data[period_key] ||= 0
      grouped_data[period_key] += entry.hours
    end
    
    # Fill missing periods for proper date range handling (show unlogged periods as 0.00)
    if grouping == 'weekly'
      grouped_data = fill_missing_weeks_team(grouped_data, @from, @to)
    elsif grouping == 'monthly'
      grouped_data = fill_missing_months_team(grouped_data, @from, @to)
    end
    
    # Sort by period key in ASCENDING order (oldest first for chart, like Individual Dashboard)
    sorted_data = grouped_data.sort_by { |key, _| key }
    
    # Format labels and values
    labels = sorted_data.map { |period, _| format_chart_label_for_team(period, grouping) }
    values = sorted_data.map { |_, hours| hours.round(2) }
    
    raw_keys = sorted_data.map(&:first)
    generate_line_chart_from_data(labels, values, raw_keys, grouping)
  end

  def generate_time_entries_stacked_chart_data(entries, grouping)
    return empty_chart_data('bar') if entries.blank?

    category_breakdown = {}

    entries.includes(:activity).each do |entry|
      period_key = get_activity_period_key(entry.spent_on, grouping)
      activity_name = entry.activity&.name || 'No Activity'

      category_breakdown[period_key] ||= {}
      category_breakdown[period_key][activity_name] ||= 0
      category_breakdown[period_key][activity_name] += entry.hours
    end

    activity_totals = Hash.new(0)
    category_breakdown.each_value do |activities|
      activities.each { |activity, hours| activity_totals[activity] += hours }
    end
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
    
    # Get all time entries with their details
    entries_with_details = time_entries.includes(:activity).map do |entry|
      period_key = get_activity_period_key(entry.spent_on, grouping)
      activity_name = entry.activity&.name || 'No Activity'
      {
        period_key: period_key,
        activity_name: activity_name,
        hours: entry.hours
      }
    end
    
    # Get unique periods and activities
    periods = entries_with_details.map { |e| e[:period_key] }.uniq.sort
    activities = entries_with_details.map { |e| e[:activity_name] }.uniq
    
    # Initialize matrix with zeros
    matrix_data = {}
    periods.each { |period| matrix_data[period] = {} }
    
    # Populate matrix data
    entries_with_details.each do |entry|
      period = entry[:period_key]
      activity = entry[:activity_name]
      matrix_data[period][activity] ||= 0
      matrix_data[period][activity] += entry[:hours]
    end
    
    # Calculate totals
    period_totals = {}
    activity_totals = {}
    grand_total = 0
    
    periods.each do |period|
      period_totals[period] = activities.sum { |activity| matrix_data[period][activity] || 0 }
      grand_total += period_totals[period]
    end
    
    activities.each do |activity|
      activity_totals[activity] = periods.sum { |period| matrix_data[period][activity] || 0 }
    end

    # Keep activity order consistent across stacked chart and donut chart colors
    activities = activities.sort_by { |activity| -(activity_totals[activity] || 0) }
    
    {
      periods: periods.map { |p| format_activity_period_display(p, grouping) },
      activities: activities,
      matrix: matrix_data,
      period_totals: period_totals,
      activity_totals: activity_totals,
      grand_total: grand_total,
      raw_periods: periods # Keep original keys for matrix lookup
    }
  end

  # Get period key for activity grouping (matches Time Entries format)
  def get_activity_period_key(date, grouping)
    case grouping
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
      labels = pivot_data[:raw_periods].map { |period| format_activity_period_display(period, @grouping) }
      data_values = pivot_data[:raw_periods].map { |period| pivot_data[:period_totals][period] || 0 }
      generate_line_chart_from_data(labels, data_values, pivot_data[:raw_periods], @grouping)
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
  def generate_line_chart_from_data(labels, data_values, raw_keys = nil, grouping = nil)
    # Generate detailed tooltip labels for weekly grouping
    tooltip_labels = if raw_keys && grouping == 'weekly'
      raw_keys.map { |key| helpers.format_period_for_tooltip(key, grouping, @from, @to) }
    else
      labels
    end
    
    primary_color = '#36a2eb'

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
        pointRadius: 3,
        pointHoverRadius: 5,
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
    
    # Get all time entries with their details
    entries_with_details = time_entries.includes(:project).map do |entry|
      period_key = get_activity_period_key(entry.spent_on, grouping)
      
      # Group personal projects under "Personal Projects"
      project_name = if personal_project_ids.include?(entry.project_id)
                       'Personal Projects'
                     else
                       entry.project&.name || 'No Project'
                     end
      
      {
        period_key: period_key,
        project_name: project_name,
        hours: entry.hours
      }
    end
    
    # Get unique periods and projects (temporarily without sorting projects)
    periods = entries_with_details.map { |e| e[:period_key] }.uniq.sort
    projects_unsorted = entries_with_details.map { |e| e[:project_name] }.uniq
    
    # Initialize matrix with zeros
    matrix_data = {}
    periods.each { |period| matrix_data[period] = {} }
    
    # Populate matrix data
    entries_with_details.each do |entry|
      period = entry[:period_key]
      project = entry[:project_name]
      matrix_data[period][project] ||= 0
      matrix_data[period][project] += entry[:hours]
    end
    
    # Calculate project totals first
    project_totals = {}
    projects_unsorted.each do |project|
      project_totals[project] = periods.sum { |period| matrix_data[period][project] || 0 }
    end
    
    # Sort projects by total hours descending (largest to smallest)
    projects = projects_unsorted.sort_by { |project| -project_totals[project] }
    
    # Calculate period totals and grand total
    period_totals = {}
    grand_total = 0
    
    periods.each do |period|
      period_totals[period] = projects.sum { |project| matrix_data[period][project] || 0 }
      grand_total += period_totals[period]
    end
    
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
      labels = pivot_data[:raw_periods].map { |period| format_activity_period_display(period, @grouping) }
      data_values = pivot_data[:raw_periods].map { |period| pivot_data[:period_totals][period] || 0 }
      generate_line_chart_from_data(labels, data_values, pivot_data[:raw_periods], @grouping)
    end
  end

  # Generate Member × Time Period pivot table
  def generate_member_pivot_table(time_entries, grouping)
    Rails.logger.info "Generating member pivot table for grouping: #{grouping}, entries count: #{time_entries.count}"
    
    # Get all time entries with their details, including user IDs
    entries_with_details = time_entries.includes(:user).map do |entry|
      period_key = get_activity_period_key(entry.spent_on, grouping)
      user = entry.user
      member_data = { id: user.id, name: user.name } # Store both ID and name
      
      {
        period_key: period_key,
        member_data: member_data,
        hours: entry.hours
      }
    end
    
    # Get unique periods and members (temporarily without sorting members)
    periods = entries_with_details.map { |e| e[:period_key] }.uniq.sort
    members_unsorted = entries_with_details.map { |e| e[:member_data] }.uniq { |m| m[:id] }
    
    # Initialize matrix with zeros (use member name as key for lookup)
    matrix_data = {}
    periods.each { |period| matrix_data[period] = {} }
    
    # Populate matrix data (use member name as key)
    entries_with_details.each do |entry|
      period = entry[:period_key]
      member_name = entry[:member_data][:name]
      matrix_data[period][member_name] ||= 0
      matrix_data[period][member_name] += entry[:hours]
    end
    
    # Calculate member totals first (using member name)
    member_totals = {}
    members_unsorted.each do |member_data|
      member_name = member_data[:name]
      member_totals[member_name] = periods.sum { |period| matrix_data[period][member_name] || 0 }
    end
    
    # Sort members by total hours descending (largest to smallest)
    members = members_unsorted.sort_by { |member_data| -member_totals[member_data[:name]] }
    
    # Calculate period totals and grand total
    period_totals = {}
    grand_total = 0
    
    periods.each do |period|
      period_totals[period] = members.sum { |member_data| matrix_data[period][member_data[:name]] || 0 }
      grand_total += period_totals[period]
    end
    
    {
      periods: periods.map { |p| format_activity_period_display(p, grouping) },
      members: members, # Array of {id:, name:} hashes
      matrix: matrix_data, # Still keyed by member name for lookup
      period_totals: period_totals,
      member_totals: member_totals, # Keyed by member name
      grand_total: grand_total,
      raw_periods: periods # Keep original keys for matrix lookup
    }
  end

  # Generate chart data for member pivot table
  def generate_member_pivot_chart_data(pivot_data, chart_type, member_view_state = 'detailed')
    case chart_type
    when 'bar'
      member_names = pivot_data[:members].map { |member| member[:name] }
      generate_stacked_bar_chart_from_matrix(pivot_data[:raw_periods], member_names, pivot_data[:matrix], @grouping)
    else
      labels = pivot_data[:raw_periods].map { |period| format_activity_period_display(period, @grouping) }
      data_values = pivot_data[:raw_periods].map { |period| pivot_data[:period_totals][period] || 0 }
      generate_line_chart_from_data(labels, data_values, pivot_data[:raw_periods], @grouping)
    end
  end

  def generate_stacked_bar_chart_from_matrix(period_keys, categories, matrix_data, grouping)
    return empty_chart_data('bar') if period_keys.blank? || categories.blank?

    sorted_periods = period_keys.uniq.sort
    sorted_periods = if grouping == 'weekly'
      fill_missing_weeks_team(sorted_periods.each_with_object({}) { |period_key, hash| hash[period_key] = 0 }, @from, @to).keys.sort
    else
      fill_missing_months_team(sorted_periods.each_with_object({}) { |period_key, hash| hash[period_key] = 0 }, @from, @to).keys.sort
    end

    formatted_labels = sorted_periods.map { |key| format_activity_period_display(key, grouping) }
    tooltip_labels = if grouping == 'weekly'
      sorted_periods.map { |key| helpers.format_period_for_tooltip(key, grouping, @from, @to) }
    else
      formatted_labels
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

    {
      type: 'bar',
      data: {
        labels: formatted_labels,
        datasets: datasets
      },
      options: {
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
          xAxes: [{
            stacked: true,
            scaleLabel: {
              display: true,
              labelString: helpers.grouping_label(grouping),
              fontSize: 12,
              fontStyle: 'bold'
            },
            ticks: {
              maxRotation: 45,
              minRotation: 45,
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
    
    working_days = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(period_start, period_end)
    return 0 if working_days.zero?

    leave_days = calculate_team_leave_days_for_period(period_start, period_end)
    team_active_days = (working_days * team_size) - leave_days
    return 0 if team_active_days <= 0

    (hours / team_active_days).round(2)
  end

  # Calculate team size for a specific period based on membership dates (not time logging)
  def calculate_team_size_for_period(period_date, grouping)
    # Get excluded user IDs
    excluded_ids = TaTeamSetting.excluded_user_ids
    
    # Determine period start and end dates based on grouping
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
                                  # Default to weekly
                                  week_start = period_date.beginning_of_week(:monday)
                                  week_end = week_start + 6.days
                                  [week_start, week_end]
                                end
    
    # Count members who were active during this period (based on membership dates, not time entries)
    active_count = @team_members.count do |membership|
      user_id = membership.user_id
      start_date = membership.start_date
      end_date = membership.end_date
      
      # Skip if member is in excluded list
      next false if excluded_ids.include?(user_id)
      
      # Member is active during period if:
      # - Their start_date is on or before the period ends (start_date <= period_end)
      # - AND their end_date is either NULL (still active) OR on or after the period starts (end_date >= period_start)
      start_date <= period_end && (end_date.nil? || end_date >= period_start)
    end
    
    active_count
  end

  def calculate_team_leave_days_for_period(period_start, period_end)
    excluded_ids = TaTeamSetting.excluded_user_ids
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

  # Format chart label for team dashboard (proper week format: YYYY-WW)
  def format_chart_label_for_team(period, grouping)
    case grouping
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
