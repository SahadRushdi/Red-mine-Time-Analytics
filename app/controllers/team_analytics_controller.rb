class TeamAnalyticsController < ApplicationController
  before_action :require_login
  before_action :set_date_range
  before_action :set_grouping
  helper :time_analytics
  helper :ta_teams

  def index
    # Get teams where current user is a lead
    @teams = User.current.led_teams
    
    # Return 403 if user is not a team lead
    return render_403 unless @teams.any?
    
    # Get selected team (must be one of the user's led teams)
    @selected_team = if params[:team_id].present? && params[:team_id] != ""
      team = TaTeam.find_by(id: params[:team_id])
      # Security check: ensure user is a lead for this team
      @teams.include?(team) ? team : @teams.first
    else
      @teams.first
    end
    
    Rails.logger.info "Team Analytics: Selected team: #{@selected_team&.name}, Date range: #{@from} to #{@to}"
    
    @view_mode = params[:view_mode] || 'time_entries'
    
    # Get excluded user IDs from settings
    excluded_ids = TaTeamSetting.excluded_user_ids
    
    # Get team members - consider team configuration as retroactive
    # If a member is in the team now (or was during analysis period), 
    # we should be able to analyze their historical data
    # Only exclude members who left BEFORE the analysis period starts
    @team_members = TaTeamMembership.where(team: @selected_team)
                                    .where('end_date IS NULL OR end_date >= ?', @from)
                                    .includes(:user)
    
    @member_ids = @team_members.map(&:user_id)
    
    # Filter out excluded users
    @active_member_ids = @member_ids - excluded_ids
    @team_size = @active_member_ids.count
    
    Rails.logger.info "Team Analytics: Team members: #{@member_ids.count}, Active members: #{@active_member_ids.count}, Excluded: #{excluded_ids.count}"
    
    # Get time entries for all active team members on ALL projects where they have logged time
    # Filter by member start_date and end_date within the selected date range
    # Build conditions to respect each member's start date and end date
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
                                 .order('time_entries.spent_on DESC, time_entries.created_on DESC') if @time_entries
    
    # If no members or conditions, return empty relation
    @time_entries ||= TimeEntry.none
    
    Rails.logger.info "Team Analytics: Auto-discovered projects from member time logs"
    
    # Apply search filter if present
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      @time_entries = @time_entries.where(
        "LOWER(projects.name) LIKE LOWER(?) OR LOWER(issues.subject) LIKE LOWER(?) OR LOWER(time_entries.comments) LIKE LOWER(?) OR LOWER(users.firstname) LIKE LOWER(?) OR LOWER(users.lastname) LIKE LOWER(?)",
        search_term, search_term, search_term, search_term, search_term
      )
    end
    
    # Calculate team statistics
    @total_hours = @time_entries.sum(:hours)
    @entry_count = @time_entries.count
    
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
    
    # Generate Time Overview data with team member count
    @time_overview_data = generate_team_time_overview_data(@time_entries, @grouping)
    
    # Handle view-specific data preparation
    if @view_mode == 'time_entries'
      # Time Overview: Group by selected period (daily/weekly/monthly/yearly)
      # Show Date, Team Member Count, Hours
      @entry_count = @time_overview_data.count
      @paginated_entries = @time_overview_data.slice(@offset, @limit)
      
      # Generate chart data
      chart_type = params[:chart_type] || 'line'
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
      
      # For pagination, use periods count
      @entry_count = @time_periods.count
      @paginated_periods = @time_periods.slice(@offset, @limit)
      
      # Track activity view state for chart generation
      @activity_view_state = params[:activity_view_state] || 'detailed'
      
      # Generate chart data
      chart_type = params[:chart_type] || 'pie'
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
      
      # For pagination, use periods count
      @entry_count = @time_periods.count
      @paginated_periods = @time_periods.slice(@offset, @limit)
      
      # Track project view state for chart generation
      @project_view_state = params[:project_view_state] || 'detailed'
      
      # Generate chart data
      chart_type = params[:chart_type] || 'pie'
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
      
      # For pagination, use periods count
      @entry_count = @time_periods.count
      @paginated_periods = @time_periods.slice(@offset, @limit)
      
      # Track member view state for chart generation
      @member_view_state = params[:member_view_state] || 'detailed'
      
      # Generate chart data
      chart_type = params[:chart_type] || 'pie'
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
          chart_type: params[:chart_type] || 'line'
        } 
      }
    end
  end

  def export_csv
    # Get teams where current user is a lead
    @teams = User.current.led_teams
    return render_403 unless @teams.any?
    
    @selected_team = if params[:team_id].present?
      team = TaTeam.find_by(id: params[:team_id])
      @teams.include?(team) ? team : @teams.first
    else
      @teams.first
    end
    
    @view_mode = params[:view_mode] || 'time_entries'
    
    # Get excluded user IDs
    excluded_ids = TaTeamSetting.excluded_user_ids
    
    # Get team members - retroactive configuration
    @team_members = TaTeamMembership.where(team: @selected_team)
                                    .where('end_date IS NULL OR end_date >= ?', @from)
                                    .includes(:user)
    
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

    # Apply search filter if present
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      @time_entries = @time_entries.where(
        "LOWER(projects.name) LIKE LOWER(?) OR LOWER(issues.subject) LIKE LOWER(?) OR LOWER(time_entries.comments) LIKE LOWER(?) OR LOWER(users.firstname) LIKE LOWER(?) OR LOWER(users.lastname) LIKE LOWER(?)",
        search_term, search_term, search_term, search_term, search_term
      )
    end

    # Generate CSV based on view mode
    csv_data = export_team_time_entries_to_csv(@time_entries, @selected_team)
    filename = "team_analytics_#{@selected_team.name.parameterize}_#{@from}_#{@to}.csv"
    
    send_data csv_data, 
              filename: filename,
              type: 'text/csv'
  end

  private

  def set_date_range
    case params[:filter]
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
      @from = params[:from].present? ? Date.parse(params[:from]) : Date.current.beginning_of_month
      @to = params[:to].present? ? Date.parse(params[:to]) : Date.current.end_of_month
    else
      # Default to this month
      params[:filter] = 'this_month'
      @from = Date.current.beginning_of_month
      @to = Date.current.end_of_month
    end
  rescue ArgumentError
    # Handle invalid date format
    @from = Date.current.beginning_of_month
    @to = Date.current.end_of_month
  end

  def set_grouping
    # Default to weekly grouping for team dashboard
    @grouping = params[:grouping].presence || 'weekly'
    @grouping = 'weekly' unless %w[weekly monthly].include?(@grouping)
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
    
    # Return structured data with period, team_size (not member_count), and hours
    sorted_data.map do |period, hours|
      # Convert period key to appropriate format for the helper
      period_for_display = case grouping
                           when 'monthly'
                             # Convert [year, month] array to first day of month
                             Date.new(period[0], period[1], 1)
                           else
                             period
                           end
      
      period_label = helpers.format_period_for_table(period_for_display, grouping, @from, @to)
      # Calculate actual team size for this specific period based on membership dates
      team_size = calculate_team_size_for_period(period_for_display, grouping)
      
      Struct.new(:period, :member_count, :hours).new(period_label, team_size, hours)
    end
  end

  # Generate chart data for team view
  def generate_team_chart_data(entries, grouping, chart_type)
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
    
    # For weekly grouping, prepare tooltip labels with date ranges
    tooltip_labels = if grouping == 'weekly'
                      sorted_data.map do |period, _|
                        week_start = period
                        week_end = period + 6.days
                        # Clip to user's selected date range
                        display_start = [week_start, @from].max
                        display_end = [week_end, @to].min
                        "#{display_start.strftime('%m/%d/%Y')} to #{display_end.strftime('%m/%d/%Y')}"
                      end
                    else
                      nil
                    end
    
    # Build complete Chart.js config (matching Individual Dashboard structure)
    chart_data = {
      labels: labels,
      datasets: [{
        label: chart_type == 'pie' ? 'Team Hours' : 'Hours',
        data: values,
        tooltipLabels: tooltip_labels,  # Add tooltip labels for weekly view
        backgroundColor: case chart_type
                         when 'pie'
                           generate_colors(values.length)
                         when 'bar'
                           generate_colors(values.length)
                         else # line
                           'rgba(54, 162, 235, 0.1)'
                         end,
        borderColor: chart_type == 'pie' ? '#fff' : '#36a2eb',
        borderWidth: chart_type == 'pie' ? 1 : (chart_type == 'bar' ? 1 : 2),
        fill: chart_type == 'line' ? true : (chart_type == 'pie' ? false : true),
        tension: chart_type == 'line' ? 0.2 : 0,
        pointRadius: chart_type == 'line' ? 3 : 0,
        pointHoverRadius: chart_type == 'line' ? 5 : 0
      }]
    }
    
    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          display: chart_type == 'pie',
          position: 'right'
        },
        tooltip: {
          enabled: true,
          backgroundColor: 'rgba(0,0,0,0.7)',
          titleColor: '#fff',
          bodyColor: '#fff',
          borderColor: 'rgba(0,0,0,0.8)',
          borderWidth: 1
        }
      },
      scales: chart_type == 'pie' ? {} : {
        y: {
          beginAtZero: true,
          title: {
            display: true,
            text: 'Hours',
            font: {
              size: 12,
              weight: 'bold'
            }
          },
          grid: {
            display: true,
            color: 'rgba(0, 0, 0, 0.1)',
            drawBorder: true,
            drawOnChartArea: true,
            drawTicks: true
          },
          ticks: {
            font: {
              size: 11
            }
          }
        },
        x: {
          title: {
            display: true,
            text: grouping.capitalize,
            font: {
              size: 12,
              weight: 'bold'
            }
          },
          grid: {
            display: true,
            color: 'rgba(0, 0, 0, 0.05)',
            drawBorder: true,
            drawOnChartArea: true,
            drawTicks: true
          },
          ticks: {
            font: {
              size: 10
            },
            maxRotation: 45,
            minRotation: 45,
            autoSkip: true,
            autoSkipPadding: 10
          }
        }
      }
    }
    
    # Return full Chart.js configuration
    {
      type: chart_type,
      data: chart_data,
      options: chart_options
    }.to_json.html_safe
  end

  def generate_colors(count)
    colors = [
      '#FF6384', '#36A2EB', '#FFCE56', '#4BC0C0', '#9966FF',
      '#FF9F40', '#8AC249', '#EA5F89', '#00D1B2', '#958AF7'
    ]
    
    if count <= colors.size
      colors.take(count)
    else
      result = colors.dup
      (count - colors.size).times do |i|
        hue = (i * 137.5) % 360
        result << "hsl(#{hue}, 70%, 60%)"
      end
      result
    end
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
    activities = entries_with_details.map { |e| e[:activity_name] }.uniq.sort
    
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
      period_key.strftime('%B %Y') # "October 2025"
    else
      # Default to weekly
      helpers.format_period_for_table(period_key, grouping, @from, @to)
    end
  end

  # Generate chart data for activity pivot table
  def generate_activity_pivot_chart_data(pivot_data, chart_type, activity_view_state = 'detailed')
    # Determine what data to use based on view state
    if activity_view_state == 'summary'
      # Summary view: group by activity, sorted by hours (descending)
      sorted_activities = pivot_data[:activities].sort_by { |activity| -(pivot_data[:activity_totals][activity] || 0) }
      labels = sorted_activities
      data_values = sorted_activities.map { |activity| pivot_data[:activity_totals][activity] || 0 }
      raw_keys = nil  # No raw keys for activity names
    else
      # Detailed view: group by time period, sorted by hours (descending)
      combined = pivot_data[:raw_periods].map do |period|
        {
          raw_key: period,
          label: pivot_data[:periods][pivot_data[:raw_periods].index(period)],
          value: pivot_data[:period_totals][period] || 0
        }
      end
      sorted_combined = combined.sort_by { |item| -item[:value] }
      
      labels = sorted_combined.map { |item| item[:label] }
      data_values = sorted_combined.map { |item| item[:value] }
      raw_keys = sorted_combined.map { |item| item[:raw_key] }
    end
    
    case chart_type
    when 'pie'
      generate_pie_chart_from_data(labels, data_values, raw_keys, @grouping)
    when 'line'
      generate_line_chart_from_data(labels, data_values, raw_keys, @grouping)
    else
      generate_bar_chart_from_data(labels, data_values, raw_keys, @grouping)
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
        backgroundColor: generate_colors(labels.size),
        borderWidth: 1,
        tooltipLabels: tooltip_labels
      }]
    }

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          display: false
        },
        tooltip: {
          callbacks: {
            title: (grouping == 'weekly' && raw_keys) ? 
              "function(context) { return context[0].dataset.tooltipLabels[context[0].dataIndex]; }" : nil
          }.compact
        }
      },
      scales: {
        y: {
          beginAtZero: true,
          title: {
            display: true,
            text: 'Hours'
          }
        },
        x: {
          title: {
            display: true,
            text: grouping ? helpers.grouping_label(grouping) : ''
          },
          ticks: {
            maxRotation: 45,
            minRotation: 45
          }
        }
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
    
    chart_data = {
      labels: labels,
      datasets: [{
        label: 'Hours',
        data: data_values,
        borderColor: '#36a2eb',
        backgroundColor: 'rgba(54, 162, 235, 0.1)',
        fill: true,
        tension: 0.2,
        borderWidth: 2,
        pointRadius: 3,
        pointHoverRadius: 5,
        tooltipLabels: tooltip_labels
      }]
    }

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          display: false
        },
        tooltip: {
          callbacks: {
            title: (grouping == 'weekly' && raw_keys) ? 
              "function(context) { return context[0].dataset.tooltipLabels[context[0].dataIndex]; }" : nil
          }.compact
        }
      },
      scales: {
        y: {
          beginAtZero: true,
          title: {
            display: true,
            text: 'Hours'
          }
        },
        x: {
          title: {
            display: true,
            text: grouping ? helpers.grouping_label(grouping) : ''
          },
          ticks: {
            maxRotation: 45,
            minRotation: 45
          }
        }
      }
    }

    {
      type: 'line',
      data: chart_data,
      options: chart_options
    }.to_json.html_safe
  end

  # Generate pie chart from data arrays
  def generate_pie_chart_from_data(labels, data_values, raw_keys = nil, grouping = nil)
    # Calculate total for percentage calculation
    total_hours = data_values.sum
    
    # Generate detailed tooltip labels for weekly grouping
    tooltip_labels = if raw_keys && grouping == 'weekly'
      raw_keys.map { |key| helpers.format_period_for_tooltip(key, grouping, @from, @to) }
    else
      labels
    end
    
    # Format labels with percentages and hours for pie chart
    labels_with_percentages = labels.each_with_index.map do |label, index|
      hours = data_values[index]
      percentage = total_hours > 0 ? ((hours / total_hours) * 100).round(1) : 0
      "#{label} (#{percentage}%, #{hours.round(1)}h)"
    end
    
    chart_data = {
      labels: labels_with_percentages,
      datasets: [{
        data: data_values,
        backgroundColor: generate_colors(labels.size),
        borderWidth: 1,
        borderColor: '#fff',
        tooltipLabels: tooltip_labels
      }]
    }

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          position: 'right',
          labels: {
            padding: 15,
            boxWidth: 12
          }
        },
        tooltip: {
          callbacks: {
            title: (grouping == 'weekly' && raw_keys) ? 
              "function(context) { return context[0].dataset.tooltipLabels[context[0].dataIndex]; }" : nil
          }.compact
        }
      },
      # Add total hours for percentage calculation in JavaScript
      total_hours: total_hours
    }

    {
      type: 'pie',
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
    # Determine what data to use based on view state
    if project_view_state == 'summary'
      # Summary view: group by project
      labels = pivot_data[:projects]
      data_values = pivot_data[:projects].map { |project| pivot_data[:project_totals][project] || 0 }
      raw_keys = nil  # No raw keys for project names
    else
      # Detailed view: group by time period
      labels = pivot_data[:periods]
      data_values = pivot_data[:raw_periods].map { |period| pivot_data[:period_totals][period] || 0 }
      raw_keys = pivot_data[:raw_periods]  # Pass raw period keys for tooltip formatting
    end
    
    case chart_type
    when 'pie'
      generate_pie_chart_from_data(labels, data_values, raw_keys, @grouping)
    when 'line'
      generate_line_chart_from_data(labels, data_values, raw_keys, @grouping)
    else
      generate_bar_chart_from_data(labels, data_values, raw_keys, @grouping)
    end
  end

  # Generate Member × Time Period pivot table
  def generate_member_pivot_table(time_entries, grouping)
    Rails.logger.info "Generating member pivot table for grouping: #{grouping}, entries count: #{time_entries.count}"
    
    # Get all time entries with their details
    entries_with_details = time_entries.includes(:user).map do |entry|
      period_key = get_activity_period_key(entry.spent_on, grouping)
      member_name = entry.user.name # Full name
      
      {
        period_key: period_key,
        member_name: member_name,
        hours: entry.hours
      }
    end
    
    # Get unique periods and members (temporarily without sorting members)
    periods = entries_with_details.map { |e| e[:period_key] }.uniq.sort
    members_unsorted = entries_with_details.map { |e| e[:member_name] }.uniq
    
    # Initialize matrix with zeros
    matrix_data = {}
    periods.each { |period| matrix_data[period] = {} }
    
    # Populate matrix data
    entries_with_details.each do |entry|
      period = entry[:period_key]
      member = entry[:member_name]
      matrix_data[period][member] ||= 0
      matrix_data[period][member] += entry[:hours]
    end
    
    # Calculate member totals first
    member_totals = {}
    members_unsorted.each do |member|
      member_totals[member] = periods.sum { |period| matrix_data[period][member] || 0 }
    end
    
    # Sort members by total hours descending (largest to smallest)
    members = members_unsorted.sort_by { |member| -member_totals[member] }
    
    # Calculate period totals and grand total
    period_totals = {}
    grand_total = 0
    
    periods.each do |period|
      period_totals[period] = members.sum { |member| matrix_data[period][member] || 0 }
      grand_total += period_totals[period]
    end
    
    {
      periods: periods.map { |p| format_activity_period_display(p, grouping) },
      members: members,
      matrix: matrix_data,
      period_totals: period_totals,
      member_totals: member_totals,
      grand_total: grand_total,
      raw_periods: periods # Keep original keys for matrix lookup
    }
  end

  # Generate chart data for member pivot table
  def generate_member_pivot_chart_data(pivot_data, chart_type, member_view_state = 'detailed')
    # Determine what data to use based on view state
    if member_view_state == 'summary'
      # Summary view: group by member
      labels = pivot_data[:members]
      data_values = pivot_data[:members].map { |member| pivot_data[:member_totals][member] || 0 }
      raw_keys = nil  # No raw keys for member names
    else
      # Detailed view: group by time period
      labels = pivot_data[:periods]
      data_values = pivot_data[:raw_periods].map { |period| pivot_data[:period_totals][period] || 0 }
      raw_keys = pivot_data[:raw_periods]  # Pass raw period keys for tooltip formatting
    end
    
    case chart_type
    when 'pie'
      generate_pie_chart_from_data(labels, data_values, raw_keys, @grouping)
    when 'line'
      generate_line_chart_from_data(labels, data_values, raw_keys, @grouping)
    else
      generate_bar_chart_from_data(labels, data_values, raw_keys, @grouping)
    end
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
    
    while current <= to_date
      month_key = [current.year, current.month]
      result[month_key] = grouped_data[month_key] || 0
      current = current.next_month
    end
    
    result
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
