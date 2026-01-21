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
    
    # Get active team members for selected date range
    @team_members = TaTeamMembership.where(team: @selected_team)
                                    .where('start_date <= ?', @to)
                                    .where('end_date IS NULL OR end_date >= ?', @from)
                                    .includes(:user)
    
    @member_ids = @team_members.map(&:user_id)
    
    # Filter out excluded users
    @active_member_ids = @member_ids - excluded_ids
    @team_size = @active_member_ids.count
    
    Rails.logger.info "Team Analytics: Team members: #{@member_ids.count}, Active members: #{@active_member_ids.count}, Excluded: #{excluded_ids.count}"
    
    # Get team projects
    team_project_ids = TaTeamProject.where(team: @selected_team)
                                    .where('start_date <= ?', @to)
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
      # Activity view - to be implemented
      @entry_count = 0
      @paginated_entries = []
      
    elsif @view_mode == 'project'
      # Project view - to be implemented
      @entry_count = 0
      @paginated_entries = []
      
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
    
    # Get team members and projects
    @team_members = TaTeamMembership.where(team: @selected_team)
                                    .where('start_date <= ?', @to)
                                    .where('end_date IS NULL OR end_date >= ?', @from)
                                    .includes(:user)
    
    @member_ids = @team_members.map(&:user_id)
    @active_member_ids = @member_ids - excluded_ids
    
    team_project_ids = TaTeamProject.where(team: @selected_team)
                                    .where('start_date <= ?', @to)
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
      period_label = helpers.format_period_for_table(period, grouping, @from, @to)
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
end
