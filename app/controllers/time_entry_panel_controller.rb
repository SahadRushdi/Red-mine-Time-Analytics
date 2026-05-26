class TimeEntryPanelController < ApplicationController
  before_action :require_login
  before_action :set_date_range, only: [:index]
  before_action :set_grouping, only: [:index]
  helper :time_analytics

  def index
    @user = User.current
    
    # Get issues assigned to the logged-in user
    assigned_issues = Issue.joins(:project)
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

    period_window = @from.beginning_of_day..@to.end_of_day
    period_te_dates = @time_entries.each_with_object({}) do |entry, memo|
      next unless entry.issue_id
      memo[entry.issue_id] = [memo[entry.issue_id], entry.created_on].compact.max
    end

    # Logged-tab issue dropdown: include issues active in this period.
    # Active means issue.updated_on is in range for assigned issues OR user logged time in range.
    assigned_period_issue_ids = assigned_issues.select { |issue| issue.updated_on.in?(period_window) }.map(&:id)
    period_logged_issue_ids = period_te_dates.keys
    logged_issue_ids = (assigned_period_issue_ids | period_logged_issue_ids)
    @issues = if logged_issue_ids.any?
                Issue.joins(:project)
                     .where(id: logged_issue_ids)
                     .where(projects: { status: Project::STATUS_ACTIVE })
                   .includes(:project, :tracker, :status, :priority, :assigned_to)
                     .to_a
              else
                []
              end

    @issues.sort_by! do |issue|
      period_issue_update = issue.updated_on.in?(period_window) ? issue.updated_on : nil
      [period_issue_update, period_te_dates[issue.id]].compact.max || Time.at(0)
    end
    @issues.reverse!

    updated_issue_ids = Journal.where(journalized_type: 'Issue', user_id: @user.id, created_on: period_window)
                               .distinct
                               .pluck(:journalized_id)
    updated_candidates = if updated_issue_ids.any?
                           Issue.joins(:project)
                                .where(id: updated_issue_ids)
                                .where(projects: { status: Project::STATUS_ACTIVE })
                                .includes(:project, :tracker, :status, :priority, :assigned_to)
                                .to_a
                         else
                           []
                         end

    Issue.load_visible_last_updated_by(updated_candidates, @user) if updated_candidates.any?
    @period_issues = updated_candidates.select do |issue|
      issue.updated_on.in?(period_window) && issue.last_updated_by == @user
    end
    @issues_without_logs = @period_issues

    issue_ids_for_activity = (@issues.map(&:id) | @issues_without_logs.map(&:id))
    last_te_dates = if issue_ids_for_activity.any?
                      TimeEntry.where(user_id: @user.id, issue_id: issue_ids_for_activity)
                               .group(:issue_id)
                               .maximum(:created_on)
                    else
                      {}
                    end
    @issue_last_activity = {}
    (@issues + @issues_without_logs).uniq { |issue| issue.id }.each do |issue|
      te_date = last_te_dates[issue.id]
      @issue_last_activity[issue.id] = [issue.updated_on, te_date].compact.max
    end

    @unlogged_sort = %w[asc desc].include?(params[:unlogged_sort].to_s) ? params[:unlogged_sort].to_s : 'desc'
    @issues_without_logs.sort_by! { |issue| @issue_last_activity[issue.id] || Time.at(0) }
    @issues_without_logs.reverse! if @unlogged_sort == 'desc'

    # Summary card data
    @issues_worked_count = @time_entries.map(&:issue_id).uniq.count
    @unique_projects_count = @time_entries.map(&:project_id).uniq.count
    # Count only issues relevant to the selected time period: combination of
    # period-active issues (from the Logged tab's search list) and the Unlogged list.
    @all_issues_count = (@issues.map(&:id) | @issues_without_logs.map(&:id)).count
    @period_issues_count = @period_issues.count
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

  def update_entry
    entry = TimeEntry.find_by(id: params[:id], user_id: User.current.id)
    if entry
      entry.update(
        hours:       parse_hours(params[:hours]),
        activity_id: params[:activity_id],
        comments:    params[:comments]
      )
    end
    redirect_back fallback_location: time_entry_panel_path
  end

  def destroy_entry
    entry = TimeEntry.find_by(id: params[:id], user_id: User.current.id)
    entry&.destroy
    redirect_back fallback_location: time_entry_panel_path
  end

  private

  def set_grouping
    if params[:grouping].present?
      session[:tep_grouping] = params[:grouping]
    end
    @grouping_options = short_range_filter? ? %w[daily weekly] : %w[daily weekly monthly]
    requested_grouping = params[:grouping].presence || session[:tep_grouping] || 'daily'
    @grouping = @grouping_options.include?(requested_grouping) ? requested_grouping : 'daily'
    session[:tep_grouping] = @grouping
  end

  def short_range_filter?
    %w[last_7_days last_14_days this_week last_week].include?(@filter)
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
        week_start = current
        week_end = [current + 6.days, to_date].min
        intersection_start = [week_start, from_date].max
        has_entries = raw_groups.key?(week_start)
        has_working_days = (intersection_start..week_end).any? do |date|
          RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(date)
        end
        periods << current if has_entries || has_working_days
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
          last_entry_at:  nil,
          entries:        []
        }
        issue_map[key][:logged_hours]   += entry.hours
        issue_map[key][:spent_on_dates] |= [entry.spent_on]
        issue_map[key][:last_entry_at]  = [issue_map[key][:last_entry_at], entry.created_on].compact.max
        issue_map[key][:entries]        << entry
      end

      # Compute effective "last activity" = max(issue.updated_on, last time entry created_on)
      # Sort by this descending (most recently active first)
      issue_rows = issue_map.values.map do |row|
        effective = [row[:issue].updated_on, row[:last_entry_at]].compact.max || Time.at(0)
        row.merge(effective_updated: effective, entries: row[:entries].sort_by { |e| [e.spent_on, e.created_on] })
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
      @from = parse_custom_date(params[:from]) || (Date.current - 6.days)
      @to = parse_custom_date(params[:to]) || Date.current
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

  def parse_hours(value)
    return 0.0 if value.blank?
    str = value.to_s.strip
    if str.include?(':')
      h, m = str.split(':').map(&:to_i)
      h + m / 60.0
    else
      str.to_f
    end
  end

  def parse_custom_date(value)
    return nil if value.blank?

    Date.strptime(value, '%m/%d/%Y')
  rescue ArgumentError
    Date.parse(value)
  end

end
