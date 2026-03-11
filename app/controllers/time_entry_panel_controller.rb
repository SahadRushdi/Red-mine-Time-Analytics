class TimeEntryPanelController < ApplicationController
  before_action :require_login
  before_action :set_date_range, only: [:index]
  before_action :set_grouping, only: [:index]
  helper :time_analytics

  def index
    @user = User.current
    
    # Get issues assigned to the logged-in user
    @issues = Issue.joins(:project)
                   .where(assigned_to_id: @user.id)
                   .where(projects: { status: Project::STATUS_ACTIVE })
                   .includes(:project, :tracker, :status, :priority)
                   .to_a
    
    # Get time entries for the selected date range
    @time_entries = TimeEntry.joins(:project, :issue)
                             .where(user: @user)
                             .where(spent_on: @from..@to)
                             .where(projects: { status: Project::STATUS_ACTIVE })
                             .includes(:project, :issue, :activity)
                             .order('time_entries.spent_on DESC, time_entries.created_on DESC')
    
    # Get the most recently logged time entry across ALL time (not filtered by date range)
    @last_entry = TimeEntry.joins(:project)
                           .where(user: @user)
                           .where(projects: { status: Project::STATUS_ACTIVE })
                           .order(created_on: :desc, id: :desc)
                           .first
    
    # Calculate total hours for the period
    @total_hours = @time_entries.sum(:hours)

    # Build grouped entries for the Time Logs tab
    @grouped_entries = build_grouped_entries(@time_entries.to_a, @grouping, @from, @to)

    # Build a map of the latest activity timestamp per issue
    last_te_dates = TimeEntry.where(issue_id: @issues.map(&:id), user_id: @user.id)
                              .group(:issue_id)
                              .maximum(:created_on)
    @issue_last_activity = {}
    @issues.each do |issue|
      te_date = last_te_dates[issue.id]
      @issue_last_activity[issue.id] = [issue.updated_on, te_date].compact.max
    end

    # Sort issues by most recent activity descending
    @issues = @issues.sort_by { |issue| @issue_last_activity[issue.id] }.reverse

    # Issues without time entries in this period (for "Issues Worked On" tab)
    issues_with_log_ids = @time_entries.map(&:issue_id).uniq
    @issues_without_logs = @issues.reject { |issue| issues_with_log_ids.include?(issue.id) }
    
    # Summary card data
    @issues_worked_count = issues_with_log_ids.count
    @unique_projects_count = @time_entries.map(&:project_id).uniq.count
    @all_issues_count = @issues.count
  end

  def get_activities
    issue = Issue.find(params[:issue_id])
    activities = issue.project.activities.active.sorted
    
    render json: { activities: activities.map { |a| { id: a.id, name: a.name } }.sort_by { |a| a[:name] } }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Issue not found' }, status: :not_found
  end

  def create_time_entry
    issue = Issue.find(params[:issue_id])
    
    time_entry = TimeEntry.new(
      issue: issue,
      project: issue.project,
      user: User.current,
      spent_on: params[:spent_on],
      hours: params[:hours],
      activity_id: params[:activity_id],
      comments: params[:comments]
    )
    
    if time_entry.save
      render json: { success: true, message: 'Time entry created successfully' }
    else
      render json: { success: false, errors: time_entry.errors.full_messages }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, error: 'Issue not found' }, status: :not_found
  end

  private

  def set_grouping
    if params[:grouping].present?
      session[:tep_grouping] = params[:grouping]
    end
    @grouping = params[:grouping].presence || session[:tep_grouping] || 'daily'
    @grouping = 'daily' unless %w[daily weekly monthly].include?(@grouping)
    session[:tep_grouping] = @grouping
  end

  def build_grouped_entries(entries, grouping, from_date, to_date)
    raw_groups = case grouping
    when 'weekly'
      entries.group_by { |te| te.spent_on.beginning_of_week(:monday) }
    when 'monthly'
      entries.group_by { |te| te.spent_on.beginning_of_month }
    else # daily
      entries.group_by(&:spent_on)
    end

    all_period_keys = case grouping
    when 'weekly'
      periods = []
      current = from_date.beginning_of_week(:monday)
      while current <= to_date
        periods << current
        current += 1.week
      end
      periods
    when 'monthly'
      periods = []
      current = from_date.beginning_of_month
      while current <= to_date.beginning_of_month
        periods << current
        current = current.next_month
      end
      periods
    else # daily — include working days OR days with entries (skip empty non-working days)
      (from_date..to_date).select do |date|
        RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(date) || raw_groups.key?(date)
      end
    end

    all_period_keys.sort.reverse.map do |period_key|
      period_entries = raw_groups[period_key] || []

      # Deduplicate: group entries by issue, summing hours
      issue_map = {}
      period_entries.each do |entry|
        next unless entry.issue
        key = entry.issue_id
        issue_map[key] ||= {
          issue:          entry.issue,
          logged_hours:   0.0,
          spent_on_dates: [],
          last_entry_at:  nil
        }
        issue_map[key][:logged_hours]   += entry.hours
        issue_map[key][:spent_on_dates] |= [entry.spent_on]
        issue_map[key][:last_entry_at]  = [issue_map[key][:last_entry_at], entry.created_on].compact.max
      end

      # Compute effective "last activity" = max(issue.updated_on, last time entry created_on)
      # Sort by this descending (most recently active first)
      issue_rows = issue_map.values.map do |row|
        effective = [row[:issue].updated_on, row[:last_entry_at]].compact.max || Time.at(0)
        row.merge(effective_updated: effective)
      end.sort_by { |r| r[:effective_updated] }.reverse

      {
        key:          period_key,
        issue_rows:   issue_rows,
        total_hours:  period_entries.sum(&:hours),
        entry_count:  period_entries.count
      }
    end
  end

  def set_date_range
    @filter = params[:filter]
    case @filter
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
      @filter = 'last_7_days'
      @from = Date.current - 6.days
      @to = Date.current
    end
  rescue ArgumentError
    # Handle invalid date format
    @from = Date.current - 6.days
    @to = Date.current
  end
end
