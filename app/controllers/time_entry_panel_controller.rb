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
    
    # Sort issues by last log time (by current user) or last update time
    # This ensures that issues with recent activity appear at the top of both sections
    last_log_dates = TimeEntry.where(issue_id: @issues.map(&:id), user_id: @user.id)
                              .group(:issue_id)
                              .maximum(:created_on)
    
    @issues = @issues.to_a.sort_by do |issue|
      [last_log_dates[issue.id], issue.updated_on].compact.max
    end.reverse
    
    # Get time entries for the selected date range
    @time_entries = TimeEntry.joins(:project, :issue)
                             .where(user: @user)
                             .where(spent_on: @from..@to)
                             .where(projects: { status: Project::STATUS_ACTIVE })
                             .includes(:project, :issue, :activity)
                             .order('time_entries.spent_on DESC, time_entries.created_on DESC')
    
    # Get the most recently logged time entry across ALL time (not filtered by date range)
    # This shows when the user actually last logged time, regardless of current filter
    @last_entry = TimeEntry.joins(:project)
                           .where(user: @user)
                           .where(projects: { status: Project::STATUS_ACTIVE })
                           .order(created_on: :desc, id: :desc)
                           .first
    
    # Group time entries by issue for display
    @time_entries_by_issue = @time_entries.group_by(&:issue_id)
    
    # Calculate total hours for the period
    @total_hours = @time_entries.sum(:hours)
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
