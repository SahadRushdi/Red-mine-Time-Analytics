class TeamAnalyticsController < ApplicationController
  before_action :require_login
  before_action :set_date_range
  before_action :set_grouping
  helper :time_analytics

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
    
    # Get team projects - also consider retroactive
    # Only exclude projects that were removed BEFORE the analysis period
    team_project_ids = TaTeamProject.where(team: @selected_team)
                                    .where('end_date IS NULL OR end_date >= ?', @from)
                                    .pluck(:project_id)
    
    Rails.logger.info "Team Analytics: Team projects: #{team_project_ids.inspect}"
    
    # Get time entries for all active team members on team projects
    @time_entries = TimeEntry.joins(:project)
                             .where(user_id: @active_member_ids)
                             .where(project_id: team_project_ids)
                             .where(spent_on: @from..@to)
                             .where(projects: { status: Project::STATUS_ACTIVE })
                             .includes(:user, :project, :issue, :activity)
                             .order('time_entries.spent_on DESC, time_entries.created_on DESC')
    
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
    @avg_hours_per_member = @team_size > 0 ? (@total_hours / @team_size).round(2) : 0
    
    Rails.logger.info "Team Analytics: Found #{@entry_count} time entries, Total hours: #{@total_hours}"
    
    # Calculate summary statistics based on grouping
    case @grouping
    when 'weekly'
      @avg_hours_per_period = calculate_avg_hours_per_week
      @max_period_hours = calculate_max_weekly_hours
      @min_period_hours = calculate_min_weekly_hours
    when 'monthly'
      @avg_hours_per_period = calculate_avg_hours_per_month
      @max_period_hours = calculate_max_monthly_hours
      @min_period_hours = calculate_min_monthly_hours
    when 'yearly'
      @avg_hours_per_period = calculate_avg_hours_per_year
      @max_period_hours = calculate_max_yearly_hours
      @min_period_hours = calculate_min_yearly_hours
    else # daily
      @avg_hours_per_period = calculate_avg_hours_per_day
      @max_period_hours = calculate_max_daily_hours
      @min_period_hours = calculate_min_daily_hours
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
      # Members view - to be implemented
      @entry_count = 0
      @paginated_entries = []
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
    
    # Get team members and projects - retroactive configuration
    @team_members = TaTeamMembership.where(team: @selected_team)
                                    .where('end_date IS NULL OR end_date >= ?', @from)
                                    .includes(:user)
    
    @member_ids = @team_members.map(&:user_id)
    @active_member_ids = @member_ids - excluded_ids
    
    team_project_ids = TaTeamProject.where(team: @selected_team)
                                    .where('end_date IS NULL OR end_date >= ?', @from)
                                    .pluck(:project_id)
    
    # Get time entries
    @time_entries = TimeEntry.joins(:project)
                             .where(user_id: @active_member_ids)
                             .where(project_id: team_project_ids)
                             .where(spent_on: @from..@to)
                             .where(projects: { status: Project::STATUS_ACTIVE })
                             .includes(:user, :project, :issue, :activity)
                             .order('time_entries.spent_on DESC')

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
    when 'last_7_days'
      @from = Date.current - 6.days
      @to = Date.current
    when 'last_14_days'
      @from = Date.current - 13.days
      @to = Date.current
    when 'this_week'
      @from = Date.current.beginning_of_week(:monday)
      @to = Date.current.end_of_week(:monday)
    when 'last_week'
      @from = (Date.current - 1.week).beginning_of_week(:monday)
      @to = (Date.current - 1.week).end_of_week(:monday)
    when 'this_month'
      @from = Date.current.beginning_of_month
      @to = Date.current.end_of_month
    when 'custom'
      @from = params[:from].present? ? Date.parse(params[:from]) : (Date.current - 6.days)
      @to = params[:to].present? ? Date.parse(params[:to]) : Date.current
    else
      # Default to last 7 days
      params[:filter] = 'last_7_days'
      @from = Date.current - 6.days
      @to = Date.current
    end
  rescue ArgumentError
    # Handle invalid date format
    @from = Date.current - 6.days
    @to = Date.current
  end

  def set_grouping
    # Default to daily grouping
    @grouping = params[:grouping].presence || 'daily'
    @grouping = 'daily' unless %w[daily weekly monthly yearly].include?(@grouping)
  end

  # Calculate average hours per day for team (excluding weekends and holidays)
  def calculate_avg_hours_per_day
    return 0 if @time_entries.empty?
    
    working_days = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(@from, @to)
    return 0 if working_days.zero?
    
    (@total_hours / working_days).round(2)
  end

  def calculate_max_daily_hours
    daily_totals = @time_entries.reorder(nil).group(:spent_on).sum(:hours).values
    daily_totals.max || 0
  end

  def calculate_min_daily_hours
    daily_totals = @time_entries.reorder(nil).group(:spent_on).sum(:hours).values
    return 0 if daily_totals.empty?
    daily_totals.min
  end

  # Weekly grouping calculations
  def calculate_avg_hours_per_week
    return 0 if @time_entries.empty?
    
    weekly_totals = get_weekly_totals(@time_entries)
    return 0 if weekly_totals.empty?
    
    (weekly_totals.values.sum / weekly_totals.count).round(2)
  end

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
  def calculate_avg_hours_per_month
    return 0 if @time_entries.empty?
    
    monthly_totals = get_monthly_totals(@time_entries)
    return 0 if monthly_totals.empty?
    
    (monthly_totals.values.sum / monthly_totals.count).round(2)
  end

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

  # Yearly grouping calculations
  def calculate_avg_hours_per_year
    return 0 if @time_entries.empty?
    
    yearly_totals = get_yearly_totals(@time_entries)
    return 0 if yearly_totals.empty?
    
    (yearly_totals.values.sum / yearly_totals.count).round(2)
  end

  def calculate_max_yearly_hours
    yearly_totals = get_yearly_totals(@time_entries)
    return 0 if yearly_totals.empty?
    yearly_totals.values.max
  end

  def calculate_min_yearly_hours
    yearly_totals = get_yearly_totals(@time_entries)
    return 0 if yearly_totals.empty?
    yearly_totals.values.min
  end

  def get_yearly_totals(entries)
    yearly_data = {}
    entries.each do |entry|
      year = entry.spent_on.year
      yearly_data[year] ||= 0
      yearly_data[year] += entry.hours
    end
    yearly_data
  end

  # Generate team time overview data with member count per period
  def generate_team_time_overview_data(entries, grouping)
    data = {}
    member_counts = {}
    
    entries.each do |entry|
      period_key = case grouping
                   when 'weekly'
                     entry.spent_on.beginning_of_week(:monday)
                   when 'monthly'
                     [entry.spent_on.year, entry.spent_on.month]
                   when 'yearly'
                     entry.spent_on.year
                   else # daily
                     entry.spent_on
                   end
      
      data[period_key] ||= 0
      data[period_key] += entry.hours
      
      # Track unique members per period
      member_counts[period_key] ||= Set.new
      member_counts[period_key].add(entry.user_id)
    end
    
    # Sort by period key
    sorted_data = data.sort_by { |key, _| key }
    
    # Return structured data with period, member_count, and hours
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
      member_count = member_counts[period].size
      
      Struct.new(:period, :member_count, :hours).new(period_label, member_count, hours)
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
                   when 'yearly'
                     entry.spent_on.year
                   else # daily
                     entry.spent_on
                   end
      
      grouped_data[period_key] ||= 0
      grouped_data[period_key] += entry.hours
    end
    
    # Sort by period key
    sorted_data = grouped_data.sort_by { |key, _| key }
    
    # Format labels and values
    labels = sorted_data.map { |period, _| helpers.format_chart_label(period) }
    values = sorted_data.map { |_, hours| hours.round(2) }
    
    # Build complete Chart.js config (matching Individual Dashboard structure)
    chart_data = {
      labels: labels,
      datasets: [{
        label: chart_type == 'pie' ? 'Team Hours' : 'Hours',
        data: values,
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
    when 'yearly'
      # Use first day of year as key
      Date.new(date.year, 1, 1)
    else
      date
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
    when 'yearly'
      period_key.strftime('%Y')
    else
      # Daily: Use same format as Time Entries section for consistency
      helpers.format_chart_label(period_key)
    end
  end

  # Generate chart data for activity pivot table
  def generate_activity_pivot_chart_data(pivot_data, chart_type, activity_view_state = 'detailed')
    # Determine what data to use based on view state
    if activity_view_state == 'summary'
      # Summary view: group by activity
      labels = pivot_data[:activities]
      data_values = pivot_data[:activities].map { |activity| pivot_data[:activity_totals][activity] || 0 }
      raw_keys = nil  # No raw keys for activity names
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
    
    # Get all time entries with their details
    entries_with_details = time_entries.includes(:project).map do |entry|
      period_key = get_activity_period_key(entry.spent_on, grouping)
      project_name = entry.project&.name || 'No Project'
      {
        period_key: period_key,
        project_name: project_name,
        hours: entry.hours
      }
    end
    
    # Get unique periods and projects
    periods = entries_with_details.map { |e| e[:period_key] }.uniq.sort
    projects = entries_with_details.map { |e| e[:project_name] }.uniq.sort
    
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
    
    # Calculate totals
    period_totals = {}
    project_totals = {}
    grand_total = 0
    
    periods.each do |period|
      period_totals[period] = projects.sum { |project| matrix_data[period][project] || 0 }
      grand_total += period_totals[period]
    end
    
    projects.each do |project|
      project_totals[project] = periods.sum { |period| matrix_data[period][project] || 0 }
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
end
