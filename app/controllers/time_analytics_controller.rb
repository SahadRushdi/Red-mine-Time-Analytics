class TimeAnalyticsController < ApplicationController
  before_action :require_login
  before_action :set_date_range
  before_action :set_grouping
  helper :time_analytics

  def index
    # Default to individual dashboard
    permitted_params = params.permit(:filter, :from, :to, :grouping, :search, :chart_type, :per_page, :page)
    redirect_to time_analytics_individual_dashboard_path(permitted_params)
  end

  def individual_dashboard
    @user = User.current
    @view_mode = params[:view_mode] || 'time_entries'
    
    # Get time entries for the current user with project visibility check
    @time_entries = TimeEntry.joins(:project)
                             .where(user: @user)
                             .where(spent_on: @from..@to)
                             .where(projects: { status: Project::STATUS_ACTIVE })
                             .includes(:project, :issue, :activity)
                             .order('time_entries.spent_on DESC, time_entries.created_on DESC')

    # Apply search filter if present
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      # Use database-agnostic search - ActiveRecord handles case sensitivity based on database
      @time_entries = @time_entries.where(
        "LOWER(projects.name) LIKE LOWER(?) OR LOWER(issues.subject) LIKE LOWER(?) OR LOWER(time_entries.comments) LIKE LOWER(?)",
        search_term, search_term, search_term
      )
    end

    # Calculate totals and statistics
    @total_hours = @time_entries.sum(:hours)
    @entry_count = @time_entries.count
    @avg_hours_per_day = calculate_avg_hours_per_day
    @max_daily_hours = calculate_max_daily_hours
    @min_daily_hours = calculate_min_daily_hours

    @limit = params[:per_page].present? ? params[:per_page].to_i : 25
    @offset = params[:page].present? ? (params[:page].to_i - 1) * @limit : 0

    if @view_mode == 'activity'
      # Generate Activity × Time Period pivot table for ALL groupings (including daily)
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
      
      # Also generate simple activity summary for daily toggle view
      if @grouping == 'daily'
        grouped_data = group_time_entries(@time_entries, 'activity')
        # Sort by activity name
        sorted_data = grouped_data.sort_by { |activity_name, _| activity_name || 'No Activity' }
        @paginated_entries = sorted_data.slice(@offset, @limit).map do |activity_name, hours|
          Struct.new(:period, :hours).new(activity_name || 'No Activity', hours)
        end
      end
    elsif @view_mode == 'project'
      # Generate Project × Time Period pivot table for ALL groupings (including daily)
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
      
      # Also generate simple project summary for daily toggle view
      if @grouping == 'daily'
        grouped_data = group_time_entries(@time_entries, 'project')
        # Sort by project name
        sorted_data = grouped_data.sort_by { |project_name, _| project_name || 'No Project' }
        @paginated_entries = sorted_data.slice(@offset, @limit).map do |project_name, hours|
          Struct.new(:period, :hours).new(project_name || 'No Project', hours)
        end
      end
    elsif ['weekly', 'monthly', 'yearly'].include?(@grouping)
      grouped_data = group_time_entries(@time_entries, @grouping)
      @entry_count = grouped_data.count

      # Sort by the key (which is the date/period) to ensure chronological order
      sorted_data = grouped_data.sort_by do |key, _|
        # The key itself (date, year/month array, etc.) is sortable
        key
      end

      @paginated_entries = sorted_data.slice(@offset, @limit).map do |period, hours|
        # Use a Struct for easier access in the view, like an object
        Struct.new(:period, :hours).new(helpers.format_period_for_table(period, @grouping, @from, @to), hours)
      end
    else # Daily grouping
      # This is the original logic for daily entries
      @entry_count = @time_entries.count
      @paginated_entries = @time_entries.limit(@limit).offset(@offset)
    end

    # Generate chart data based on prepared data
    # Set default chart type based on view mode if not specified
    chart_type = params[:chart_type] || get_default_chart_type(@view_mode)
    
    # Track activity/project view state (summary vs detailed) for chart generation
    @activity_view_state = params[:activity_view_state] || 'detailed'
    @project_view_state = params[:project_view_state] || 'detailed'
    
    Rails.logger.info "Generating chart with type: #{chart_type}, view_mode: #{@view_mode}, grouping: #{@grouping}, activity_view_state: #{@activity_view_state}, project_view_state: #{@project_view_state}"
    
    if @view_mode == 'activity' && ['weekly', 'monthly', 'yearly'].include?(@grouping) && defined?(@activity_pivot_data)
      @chart_data = generate_activity_pivot_chart_data(@activity_pivot_data, chart_type, @activity_view_state)
    elsif @view_mode == 'project' && ['weekly', 'monthly', 'yearly'].include?(@grouping) && defined?(@project_pivot_data)
      @chart_data = generate_project_pivot_chart_data(@project_pivot_data, chart_type, @project_view_state)
    else
      @chart_data = generate_chart_data(@time_entries, @grouping, chart_type, @view_mode, @activity_view_state, @project_view_state)
    end
    
    @total_pages = (@entry_count.to_f / @limit).ceil

    respond_to do |format|
      format.html
      format.json { 
        # Parse the chart data JSON string back to hash for JSON response
        chart_data_hash = JSON.parse(@chart_data)
        render json: { 
          chart_data: chart_data_hash, 
          total_hours: @total_hours,
          chart_type: params[:chart_type] || 'bar'
        } 
      }
    end
  end

  def team_dashboard
    # Placeholder for future implementation
    render plain: "Team Dashboard - Coming Soon"
  end

  def custom_dashboard
    # Placeholder for future implementation
    render plain: "Custom Dashboard - Coming Soon"
  end

  def export_csv
    @user = User.current
    @view_mode = params[:view_mode] || 'time_entries'
    
    @time_entries = TimeEntry.joins(:project)
                             .where(user: @user)
                             .where(spent_on: @from..@to)
                             .where(projects: { status: Project::STATUS_ACTIVE })
                             .includes(:project, :issue, :activity)
                             .order('time_entries.spent_on DESC')

    # Apply search filter if present
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      # Use database-agnostic search - ActiveRecord handles case sensitivity based on database
      @time_entries = @time_entries.where(
        "LOWER(projects.name) LIKE LOWER(?) OR LOWER(issues.subject) LIKE LOWER(?) OR LOWER(time_entries.comments) LIKE LOWER(?)",
        search_term, search_term, search_term
      )
    end

    if @view_mode == 'activity'
      csv_data = export_activity_analysis_to_csv(@time_entries)
      filename = "time_analytics_activity_#{@user.login}_#{@from}_#{@to}.csv"
    elsif @view_mode == 'project'
      csv_data = export_project_analysis_to_csv(@time_entries)
      filename = "time_analytics_project_#{@user.login}_#{@from}_#{@to}.csv"
    else
      csv_data = export_time_entries_to_csv(@time_entries)
      filename = "time_analytics_#{@user.login}_#{@from}_#{@to}.csv"
    end
    
    send_data csv_data, 
              filename: filename,
              type: 'text/csv'
  end

  private

  def get_default_chart_type(view_mode)
    case view_mode
    when 'time_entries'
      'bar'
    when 'activity'
      'pie'
    when 'project'
      'pie'
    else
      'bar'
    end
  end

  def set_date_range
    case params[:filter]
    when 'today'
      @from = @to = Date.current
    when 'this_week'
      @from = Date.current.beginning_of_week(:monday)
      @to = Date.current.end_of_week(:monday)
    when 'last_week'
      @from = (Date.current - 1.week).beginning_of_week(:monday)
      @to = (Date.current - 1.week).end_of_week(:monday)
    when 'this_month'
      @from = Date.current.beginning_of_month
      @to = Date.current.end_of_month
    when 'this_year'
      @from = Date.current.beginning_of_year
      @to = Date.current.end_of_year
    when 'custom'
      @from = params[:from].present? ? Date.parse(params[:from]) : (Date.current - 30.days)
      @to = params[:to].present? ? Date.parse(params[:to]) : Date.current
    else
      # Default to this week
      params[:filter] = 'this_week'
      @from = Date.current.beginning_of_week(:monday)
      @to = Date.current.end_of_week(:monday)
    end
  rescue ArgumentError
    # Handle invalid date format
    @from = Date.current - 30.days
    @to = Date.current
  end

  def set_grouping
    # Store grouping in session for persistence
    if params[:grouping].present?
      session[:time_analytics_grouping] = params[:grouping]
    end
    
    # Use session grouping if no parameter provided
    @grouping = params[:grouping].presence || session[:time_analytics_grouping] || 'daily'
    @grouping = 'daily' unless %w[daily weekly monthly yearly].include?(@grouping)
    
    # Update session with valid grouping
    session[:time_analytics_grouping] = @grouping
  end

  def calculate_avg_hours_per_day
    return 0 if @time_entries.empty?
    
    # Calculate working days in the date range (excluding weekends and Sri Lankan holidays)
    working_days = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(@from, @to)
    return 0 if working_days.zero?
    
    (@total_hours / working_days).round(2)
  end

  def calculate_max_daily_hours
    # Remove order clause to avoid ambiguity in GROUP BY
    daily_totals = @time_entries.reorder(nil).group(:spent_on).sum(:hours).values
    daily_totals.max || 0
  end

  def calculate_min_daily_hours
    # Remove order clause to avoid ambiguity in GROUP BY
    daily_totals = @time_entries.reorder(nil).group(:spent_on).sum(:hours).values
    return 0 if daily_totals.empty?
    daily_totals.min
  end

  # Inline Chart Helper methods
  def generate_chart_data(time_entries, grouping, chart_type, view_mode = 'time_entries', activity_view_state = 'detailed', project_view_state = 'detailed')
    # Group data by the specified view mode and grouping
    # For activity view, use activity_view_state to determine grouping
    # For project view, use project_view_state to determine grouping
    if view_mode == 'activity'
      # Summary view: always group by activity
      # Detailed view: group by selected time period (daily/weekly/monthly/yearly)
      grouped_data = activity_view_state == 'summary' ? group_time_entries(time_entries, 'activity') : group_time_entries(time_entries, grouping)
    elsif view_mode == 'project'
      # Summary view: always group by project
      # Detailed view: group by selected time period (daily/weekly/monthly/yearly)
      grouped_data = project_view_state == 'summary' ? group_time_entries(time_entries, 'project') : group_time_entries(time_entries, grouping)
    else
      grouped_data = group_time_entries(time_entries, grouping)
    end
    
    case chart_type
    when 'pie'
      generate_pie_chart_data(grouped_data, view_mode)
    when 'line'
      generate_line_chart_data(grouped_data, view_mode)
    else
      generate_bar_chart_data(grouped_data, view_mode)
    end
  end

  def group_time_entries(time_entries, grouping)
    # Remove order clause to avoid ambiguity in GROUP BY operations
    base_query = time_entries.reorder(nil)
    
    # Get database adapter to use appropriate date functions
    adapter_name = ActiveRecord::Base.connection.adapter_name.downcase
    
    case grouping
    when 'activity'
      # Group by activity name - join with enumerations table to get activity names
      base_query.joins('LEFT JOIN enumerations ON time_entries.activity_id = enumerations.id')
                .group('enumerations.name')
                .sum(:hours)
    when 'project'
      # Group by project name - join with projects table to get project names
      base_query.joins('LEFT JOIN projects ON time_entries.project_id = projects.id')
                .group('projects.name')
                .sum(:hours)
    when 'daily'
      base_query.group(:spent_on).sum(:hours)
    when 'weekly'
      if adapter_name.include?('mysql')
        # MySQL: Group by year and week number
        base_query.group('YEARWEEK(spent_on, 1)').sum(:hours)
      elsif adapter_name.include?('postgresql')
        base_query.group('DATE_TRUNC(\'week\', spent_on)').sum(:hours)
      else
        # Fallback for other databases - group by week start date
        base_query.group("DATE(spent_on - ((STRFTIME('%w', spent_on) + 6) % 7) || ' days')").sum(:hours)
      end
    when 'monthly'
      if adapter_name.include?('mysql')
        # MySQL: Group by the first day of the month (YYYY-MM-01)
        base_query.group("DATE_FORMAT(spent_on, '%Y-%m-01')").sum(:hours)
      elsif adapter_name.include?('postgresql')
        base_query.group('DATE_TRUNC(\'month\', spent_on)').sum(:hours)
      else
        # Fallback for other databases (SQLite)
        base_query.group("DATE(spent_on, 'start of month')").sum(:hours)
      end
    when 'yearly'
      if adapter_name.include?('mysql')
        # MySQL: Group by year
        base_query.group('YEAR(spent_on)').sum(:hours)
      elsif adapter_name.include?('postgresql')
        base_query.group('DATE_TRUNC(\'year\', spent_on)').sum(:hours)
      else
        # Fallback for other databases
        base_query.group("DATE(spent_on, 'start of year')").sum(:hours)
      end
    else
      base_query.group(:spent_on).sum(:hours)
    end
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

  def generate_pie_chart_data(data_hash, view_mode = 'time_entries')
    return empty_chart_data('pie') if data_hash.empty?

    # Format labels based on the actual data type, not just view_mode
    # Check if keys are activity names (strings) or dates/periods
    first_key = data_hash.keys.first
    is_activity_data = first_key.is_a?(String)
    
    formatted_labels = if is_activity_data
      # Data grouped by activity names
      data_hash.keys.map { |key| key || 'No Activity' }
    else
      # Data grouped by time periods (dates, weeks, months, years)
      data_hash.keys.map { |key| helpers.format_period_for_table(key, @grouping, @from, @to) }
    end
    
    # Calculate total for percentage calculation
    total_hours = data_hash.values.sum
    
    # Format labels with percentages and hours for pie chart
    labels_with_percentages = formatted_labels.each_with_index.map do |label, index|
      hours = data_hash.values[index]
      percentage = total_hours > 0 ? ((hours / total_hours) * 100).round(1) : 0
      "#{label} (#{percentage}%, #{hours.round(1)}h)"
    end
    
    chart_data = {
      labels: labels_with_percentages,
      datasets: [{
        data: data_hash.values,
        backgroundColor: generate_colors(data_hash.size),
        borderWidth: 1,
        borderColor: '#fff'
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

  def generate_bar_chart_data(data_hash, view_mode = 'time_entries')
    return empty_chart_data('bar') if data_hash.empty?

    formatted_labels = if view_mode == 'activity'
      data_hash.keys.map { |key| key || 'No Activity' }
    else
      data_hash.keys.map { |key| helpers.format_period_for_table(key, @grouping, @from, @to) }
    end
    
    chart_data = {
      labels: formatted_labels,
      datasets: [{
        label: 'Hours',
        data: data_hash.values,
        backgroundColor: generate_colors(data_hash.size),
        borderWidth: 1
      }]
    }

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          display: false
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

  def generate_line_chart_data(data_hash, view_mode = 'time_entries')
    return empty_chart_data('line') if data_hash.empty?

    if view_mode == 'activity'
      # For activity view, sort by activity name
      sorted_data = data_hash.sort_by { |key, _| key || 'No Activity' }
      formatted_labels = sorted_data.map { |key, _| key || 'No Activity' }
    else
      # Sort data by date for proper line chart display
      sorted_data = data_hash.sort_by { |key, _| key.is_a?(Date) ? key : Date.parse(key.to_s) rescue Date.current }
      formatted_labels = sorted_data.map { |key, _| helpers.format_period_for_table(key, @grouping, @from, @to) }
    end
    
    chart_data = {
      labels: formatted_labels,
      datasets: [{
        label: 'Hours',
        data: sorted_data.map { |_, value| value },
        borderColor: '#36a2eb',
        backgroundColor: 'rgba(54, 162, 235, 0.1)',
        fill: true,
        tension: 0.2,
        borderWidth: 2,
        pointRadius: 3,
        pointHoverRadius: 5
      }]
    }

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          display: false
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

  def empty_chart_data(chart_type)
    {
      type: chart_type,
      data: {
        labels: ['No Data'],
        datasets: [{
          data: [1],
          backgroundColor: ['rgba(200, 200, 200, 0.2)'],
          borderColor: ['rgba(200, 200, 200, 0.6)'],
          borderWidth: 1
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false }
        }
      }
    }.to_json.html_safe
  end

  # Inline CSV Export methods
  def export_time_entries_to_csv(time_entries)
    require 'csv'
    
    CSV.generate(headers: true) do |csv|
      # Add headers
      csv << ['Date', 'Project', 'Activity', 'Issue', 'Comment', 'Hours']
      
      # Add data rows
      time_entries.each do |entry|
        csv << [
          entry.spent_on.strftime('%Y-%m-%d'),
          entry.project.name,
          entry.activity&.name || '-',
          entry.issue ? "##{entry.issue.id}: #{entry.issue.subject}" : '-',
          entry.comments || '-',
          sprintf('%.2f', entry.hours)
        ]
      end
      
      # Add summary row
      total_hours = time_entries.map { |entry| entry.hours }.sum
      csv << []
      csv << ['TOTAL', '', '', '', '', sprintf('%.2f', total_hours)]
    end
  end

  def export_activity_analysis_to_csv(time_entries)
    require 'csv'
    
    # Group by activity
    grouped_data = group_time_entries(time_entries, 'activity')
    
    CSV.generate(headers: true) do |csv|
      # Add headers
      csv << ['Activity', 'Total Hours']
      
      # Sort by activity name and add data rows
      sorted_data = grouped_data.sort_by { |activity_name, _| activity_name || 'No Activity' }
      sorted_data.each do |activity_name, hours|
        csv << [
          activity_name || 'No Activity',
          sprintf('%.2f', hours)
        ]
      end
      
      # Add summary row
      total_hours = grouped_data.values.sum
      csv << []
      csv << ['TOTAL', sprintf('%.2f', total_hours)]
    end
  end

  def export_project_analysis_to_csv(time_entries)
    require 'csv'
    
    # Group by project
    grouped_data = group_time_entries(time_entries, 'project')
    
    CSV.generate(headers: true) do |csv|
      # Add headers
      csv << ['Project', 'Total Hours']
      
      # Sort by project name and add data rows
      sorted_data = grouped_data.sort_by { |project_name, _| project_name || 'No Project' }
      sorted_data.each do |project_name, hours|
        csv << [
          project_name || 'No Project',
          sprintf('%.2f', hours)
        ]
      end
      
      # Add summary row
      total_hours = grouped_data.values.sum
      csv << []
      csv << ['TOTAL', sprintf('%.2f', total_hours)]
    end
  end

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

  def get_activity_period_key(date, grouping)
    case grouping
    when 'weekly'
      # Use Monday-based week start to match Time Entries format
      # wday: 0=Sunday, 1=Monday, ..., 6=Saturday
      # Convert to Monday-based: (wday - 1) % 7 gives days since Monday
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

  def generate_activity_pivot_chart_data(pivot_data, chart_type, activity_view_state = 'detailed')
    # Determine what data to use based on view state
    if activity_view_state == 'summary'
      # Summary view: group by activity
      labels = pivot_data[:activities]
      data_values = pivot_data[:activities].map { |activity| pivot_data[:activity_totals][activity] || 0 }
    else
      # Detailed view: group by time period
      labels = pivot_data[:periods]
      data_values = pivot_data[:raw_periods].map { |period| pivot_data[:period_totals][period] || 0 }
    end
    
    case chart_type
    when 'pie'
      generate_pie_chart_from_data(labels, data_values)
    when 'line'
      generate_line_chart_from_data(labels, data_values)
    else
      generate_bar_chart_from_data(labels, data_values)
    end
  end

  def generate_project_pivot_table(time_entries, grouping)
    Rails.logger.info "Generating project pivot table for grouping: #{grouping}, entries count: #{time_entries.count}"
    
    # Get all time entries with their details
    entries_with_details = time_entries.includes(:project).map do |entry|
      period_key = get_activity_period_key(entry.spent_on, grouping) # Reuse same period key logic
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

  def generate_project_pivot_chart_data(pivot_data, chart_type, project_view_state = 'detailed')
    # Determine what data to use based on view state
    if project_view_state == 'summary'
      # Summary view: group by project
      labels = pivot_data[:projects]
      data_values = pivot_data[:projects].map { |project| pivot_data[:project_totals][project] || 0 }
    else
      # Detailed view: group by time period
      labels = pivot_data[:periods]
      data_values = pivot_data[:raw_periods].map { |period| pivot_data[:period_totals][period] || 0 }
    end
    
    case chart_type
    when 'pie'
      generate_pie_chart_from_data(labels, data_values)
    when 'line'
      generate_line_chart_from_data(labels, data_values)
    else
      generate_bar_chart_from_data(labels, data_values)
    end
  end

  def generate_bar_chart_from_data(labels, data_values)
    chart_data = {
      labels: labels,
      datasets: [{
        label: 'Hours',
        data: data_values,
        backgroundColor: generate_colors(labels.size),
        borderWidth: 1
      }]
    }

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      scales: {
        y: {
          beginAtZero: true
        },
        x: {
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

  def generate_line_chart_from_data(labels, data_values)
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
        pointHoverRadius: 5
      }]
    }

    chart_options = {
      responsive: true,
      maintainAspectRatio: false,
      scales: {
        y: {
          beginAtZero: true
        },
        x: {
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

  def generate_pie_chart_from_data(labels, data_values)
    # Calculate total for percentage calculation
    total_hours = data_values.sum
    
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
        borderColor: '#fff'
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
end