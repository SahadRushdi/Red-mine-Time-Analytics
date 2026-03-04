class TimeEntryPanelController < ApplicationController
  before_action :require_login
  before_action :set_date_range
  helper :time_analytics

  def index
    @user = User.current
    
    # Get issues assigned to the logged-in user, ordered by latest updated first
    @issues = Issue.joins(:project)
                   .where(assigned_to_id: @user.id)
                   .where(projects: { status: Project::STATUS_ACTIVE })
                   .includes(:project, :tracker, :status, :priority)
                   .order('issues.updated_on DESC')
    
    # Get time entries for the selected date range
    @time_entries = TimeEntry.joins(:project, :issue)
                             .where(user: @user)
                             .where(spent_on: @from..@to)
                             .where(projects: { status: Project::STATUS_ACTIVE })
                             .includes(:project, :issue, :activity)
                             .order('time_entries.spent_on DESC, time_entries.created_on DESC')
    
    # Group time entries by issue for display
    @time_entries_by_issue = @time_entries.group_by(&:issue_id)
    
    # Calculate total hours for the period
    @total_hours = @time_entries.sum(:hours)
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
