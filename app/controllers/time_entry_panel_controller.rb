class TimeEntryPanelController < ApplicationController
  before_action :require_login
  before_action :set_date_range, only: [:index]
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
    
    # Group time entries by issue for display
    @time_entries_by_issue = @time_entries.group_by(&:issue_id)
    
    # Calculate total hours for the period
    @total_hours = @time_entries.sum(:hours)

    # Build a map of the latest activity timestamp per issue
    # considering both issue.updated_on and any time entry ever logged against it
    last_te_dates = TimeEntry.where(issue_id: @issues.map(&:id), user_id: @user.id)
                              .group(:issue_id)
                              .maximum(:created_on)
    @issue_last_activity = {}
    @issues.each do |issue|
      te_date = last_te_dates[issue.id]
      @issue_last_activity[issue.id] = [issue.updated_on, te_date].compact.max
    end

    # Sort issues by most recent activity (issue edit OR time entry) descending
    @issues = @issues.sort_by { |issue| @issue_last_activity[issue.id] }.reverse

    # Issues with time entries in this period (for "Your Time Logs" tab)
    @issues_with_logs = @issues.select { |issue| @time_entries_by_issue[issue.id].present? }
    
    # Issues without time entries in this period (for "Your Recent Work" tab)
    @issues_without_logs = @issues.reject { |issue| @time_entries_by_issue[issue.id].present? }
    
    # Summary card data
    @issues_worked_count = @issues_with_logs.count
    @unique_projects_count = @time_entries.map { |te| te.project_id }.uniq.count
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
