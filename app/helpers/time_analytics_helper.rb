module TimeAnalyticsHelper
  
  def time_analytics_tabs
    [
      { name: 'individual_dashboard', label: l(:label_individual_dashboard), partial: 'individual_dashboard' },
      { name: 'custom_dashboard', label: l(:label_custom_dashboard), partial: 'custom_dashboard' }
    ]
  end

  def current_tab
    params[:tab] || 'individual_dashboard'
  end

  def format_hours(hours)
    return "" if hours.nil?

    total_minutes = (hours.to_f * 60).round
    h, m = total_minutes.divmod(60)
    "%d:%02d" % [h, m]
  end

  def format_date_for_grouping(date, grouping)
    case grouping
    when 'daily'
      date.strftime('%Y-%m-%d')
    when 'weekly'
      "Week #{date.strftime('%U')} - #{date.year}"
    when 'monthly'
      date.strftime('%B %Y')
    when 'yearly'
      date.strftime('%Y')
    else
      date.strftime('%Y-%m-%d')
    end
  end

  def format_chart_label(key)
    # Handle different key formats from database grouping
    case key
    when Date, Time, DateTime
      key.strftime('%b %d, %Y')
    when String
      # Handle MySQL YEARWEEK format for weekly grouping
      if key.match?(/^\d{6}$/)
        year = key[0..3].to_i
        week = key[4..5].to_i
        # Date.commercial(year, week, 1) gives Monday. We can use this to represent the week.
        "Week #{week}, #{year}"
      else
        key
      end
    when Integer
      # Handle MySQL year grouping or YEARWEEK
      if key > 999999 # YEARWEEK format (YYYYWW)
        year = key / 100
        week = key % 100
        "Week #{week}, #{year}"
      elsif key > 1000 && key < 3000 # Likely a year
        key.to_s
      else
        key.to_s
      end
    when Array
      # Handle MySQL YEAR(spent_on), MONTH(spent_on) grouping for monthly
      if key.size == 2 && key.all? { |k| k.is_a?(Numeric) }
        year, month = key
        Date.new(year, month, 1).strftime('%b %Y')
      else
        key.join(', ')
      end
    else
      key.to_s
    end
  rescue => e
    # Return key as string if formatting fails
    key.to_s
  end

  def format_period_for_table(key, grouping, from_date, to_date)
    # This helper is used to format the 'period' column in the grouped results table.
    # It provides a more descriptive format for weeks than the chart label.
    
    if grouping == 'weekly'
      date_in_week = nil
      
      # Determine a representative date from the database key
      case key
      when Date, Time, DateTime
        # PostgreSQL/SQLite gives a date object (Monday of the week)
        date_in_week = key.to_date
      when String
        # MySQL can give a string like '202540'
        if key.match?(/^\d{6}$/)
          year = key[0..3].to_i
          week_num = key[4..5].to_i
          # Date.commercial gives the Monday of the ISO week. This is a reliable way to get a date in the correct week.
          date_in_week = Date.commercial(year, week_num, 1)
        end
      when Integer
        # MySQL can also return YEARWEEK as an integer
        if key > 100000 && key.to_s.length == 6
          year = key / 100
          week_num = key % 100
          date_in_week = Date.commercial(year, week_num, 1)
        end
      when Array
        # Handle cases like [2025, 10] for monthly, though we're in the weekly block
        # This is more of a safe fallback
        date_in_week = Date.new(key[0], key[1], 1) rescue nil
      end

      # Fallback if key parsing fails
      return format_chart_label(key) unless date_in_week

      # Calculate ISO week number (Redmine format: YYYY-W)
      week_number = date_in_week.cweek
      year = date_in_week.cwyear
      
      "#{year}-#{week_number}"
    elsif grouping == 'monthly'
      # The key from the controller is now consistently a Date or a 'YYYY-MM-DD' string
      date = key.is_a?(String) ? Date.parse(key) : key.to_date
      return date.strftime('%B %Y')
    else
      # For daily, yearly, and any other case, use the old chart label format
      format_chart_label(key)
    end
  end

  def format_period_for_tooltip(key, grouping, from_date, to_date)
    # This helper is used for chart tooltips to show detailed date ranges
    
    if grouping == 'weekly'
      date_in_week = nil
      
      # Determine a representative date from the database key
      case key
      when Date, Time, DateTime
        date_in_week = key.to_date
      when String
        if key.match?(/^\d{6}$/)
          year = key[0..3].to_i
          week_num = key[4..5].to_i
          date_in_week = Date.commercial(year, week_num, 1)
        end
      when Integer
        if key > 100000 && key.to_s.length == 6
          year = key / 100
          week_num = key % 100
          date_in_week = Date.commercial(year, week_num, 1)
        end
      end

      return key.to_s unless date_in_week

      # Calculate week start (Monday) and end (Sunday)
      days_since_monday = (date_in_week.wday - 1) % 7
      start_of_week = date_in_week - days_since_monday
      end_of_week = start_of_week + 6

      # The visible range should not extend beyond the user's selected filter range
      display_start = [start_of_week, from_date].max
      display_end = [end_of_week, to_date].min

      # Use a consistent, clear format for the date range (for tooltips)
      "#{display_start.strftime('%m/%d/%Y')} to #{display_end.strftime('%m/%d/%Y')}"
    else
      # For other groupings, use the standard table format
      format_period_for_table(key, grouping, from_date, to_date)
    end
  end

  # Builds compact 2/3-line daily chart tick labels (Chart.js v2 renders each array
  # element of a label as its own line) plus month/year boundary metadata for the
  # monthYearSeparator plugin. Only used for chart x-axes, never for table/CSV text -
  # format_chart_label/format_period_for_table remain the source of truth there.
  def build_daily_chart_axis(dates)
    labels = []
    boundaries = []
    prev_date = nil

    dates.each_with_index do |raw_date, index|
      date = raw_date.respond_to?(:to_date) ? raw_date.to_date : raw_date
      letter = date.strftime('%A')[0, 1]
      year_changed = prev_date && date.year != prev_date.year
      month_changed = prev_date.nil? || date.month != prev_date.month || year_changed

      if month_changed
        lines = [letter, date.strftime('%b %-d')]
        lines << date.year.to_s if year_changed
        labels << lines
        boundaries << { index: index, type: year_changed ? 'year' : 'month' } if prev_date
      else
        labels << [letter, date.day.to_s]
      end

      prev_date = date
    end

    { labels: labels, boundaries: boundaries }
  end

  def time_filter_options
    [
      [l(:label_last_7_days), 'last_7_days'],
      [l(:label_last_14_days), 'last_14_days'],
      [l(:label_this_week), 'this_week'],
      [l(:label_last_week), 'last_week'],
      [l(:label_this_month), 'this_month'],
      [l(:label_custom_range), 'custom']
    ]
  end

  def grouping_options
    [
      [l(:label_daily), 'daily'],
      [l(:label_weekly), 'weekly'],
      [l(:label_monthly), 'monthly']
    ]
  end

  def chart_type_options
    [
      [l(:label_bar_chart), 'bar'],
      [l(:label_line_chart), 'line']
    ]
  end

  def per_page_options
    [
      ['10', 10],
      ['25', 25],
      ['50', 50],
      ['100', 100]
    ]
  end

  def time_analytics_page_title
    case params[:action]
    when 'individual_dashboard'
      individual_dashboard_title
    when 'custom_dashboard'
      l(:label_custom_dashboard)
    else
      l(:label_time_analytics)
    end
  end

  def individual_dashboard_title
    if defined?(@user) && @user.present? && @user != User.current
      "#{h(@user.name)}'s Time"
    else
      l(:label_individual_dashboard)
    end
  end


  def dashboard_path_for(params_hash)
    if params[:controller] == 'team_analytics'
      team_analytics_path(params_hash)
    else
      my_time_path(params_hash)
    end
  end

  def pagination_links(current_page, total_pages, base_params)
    return '' if total_pages <= 1

    links = []
    
    # Previous link
    if current_page > 1
      prev_params = base_params.merge(page: current_page - 1)
      links << link_to('‹ ' + l(:label_previous), 
                       dashboard_path_for(prev_params), 
                       class: 'pagination-link')
    end
    
    # Page numbers
    start_page = [current_page - 2, 1].max
    end_page = [current_page + 2, total_pages].min
    
    (start_page..end_page).each do |page|
      if page == current_page
        links << content_tag(:span, page, class: 'pagination-current')
      else
        page_params = base_params.merge(page: page)
        links << link_to(page, dashboard_path_for(page_params), class: 'pagination-link')
      end
    end
    
    # Next link
    if current_page < total_pages
      next_params = base_params.merge(page: current_page + 1)
      links << link_to(l(:label_next) + ' ›', 
                       dashboard_path_for(next_params), 
                       class: 'pagination-link')
    end
    
    content_tag(:div, links.join(' ').html_safe, class: 'pagination')
  end

  def overview_pagination_links(current_page, total_pages, base_params)
    return '' if total_pages <= 1

    links = []
    
    # Previous link
    if current_page > 1
      prev_params = base_params.merge(overview_page: current_page - 1)
      links << link_to('‹ ' + l(:label_previous), 
                       dashboard_path_for(prev_params), 
                       class: 'pagination-link')
    end
    
    # Show only current page number to save space
    links << content_tag(:span, current_page, class: 'pagination-current')
    
    # Next link
    if current_page < total_pages
      next_params = base_params.merge(overview_page: current_page + 1)
      links << link_to(l(:label_next) + ' ›', 
                       dashboard_path_for(next_params), 
                       class: 'pagination-link')
    end
    
    content_tag(:div, links.join(' ').html_safe, class: 'pagination')
  end

  def issue_link_or_text(issue)
    if issue
      link_to "##{issue.id}: #{truncate(issue.subject, length: 50)}", 
              issue_path(issue), 
              class: 'issue-link'
    else
      content_tag(:span, '-', class: 'no-issue')
    end
  end

  def activity_name(activity)
    activity ? activity.name : '-'
  end

  def project_link(project)
    link_to project.name, project_path(project), class: 'project-link'
  end

  def default_chart_type(view_mode)
    'line'
  end

  def avg_label_for_grouping(grouping)
    case grouping
    when 'weekly'
      l(:label_avg_per_week)
    when 'monthly'
      l(:label_avg_per_month)
    when 'yearly'
      l(:label_avg_per_year)
    else
      l(:label_avg_per_day)
    end
  end

  def max_label_for_grouping(grouping)
    case grouping
    when 'weekly'
      l(:label_max_weekly)
    when 'monthly'
      l(:label_max_monthly)
    when 'yearly'
      l(:label_max_yearly)
    else
      l(:label_max_daily)
    end
  end

  def min_label_for_grouping(grouping)
    case grouping
    when 'weekly'
      l(:label_min_weekly)
    when 'monthly'
      l(:label_min_monthly)
    when 'yearly'
      l(:label_min_yearly)
    else
      l(:label_min_daily)
    end
  end

  def period_count_label_for_grouping(grouping)
    case grouping
    when 'weekly'
      l(:label_week_count)
    when 'monthly'
      l(:label_month_count)
    when 'yearly'
      l(:label_year_count)
    else
      l(:label_working_days)
    end
  end

  def grouping_label(grouping)
    case grouping
    when 'daily'
      l(:label_date)
    when 'weekly'
      l(:label_weekly)
    when 'monthly'
      l(:label_monthly)
    when 'yearly'
      l(:label_yearly)
    else
      grouping.humanize
    end
  end
  
  def activity_color(activity_name)
    colors = {
      'Development' => '#6366f1',
      'Testing' => '#3b82f6',
      'Learning' => '#10b981',
      'Design' => '#f97316',
      'Documentation' => '#8b5cf6',
      'Meeting' => '#ec4899',
      'Code Review' => '#14b8a6',
      'Bug Fix' => '#ef4444',
      'Research' => '#f59e0b',
      'Planning' => '#06b6d4'
    }
    colors[activity_name] || '#6b7280'
  end
  
  def time_overview_header(grouping)
    case grouping
    when 'daily'
      'Daily Time Log'
    when 'weekly'
      'Weekly Time Log'
    when 'monthly'
      'Monthly Time Log'
    else
      'Time Log'
    end
  end
  
  def chart_breakdown_header(grouping)
    case grouping
    when 'daily'
      'Daily Breakdown'
    when 'weekly'
      'Weekly Breakdown'
    when 'monthly'
      'Monthly Breakdown'
    else
      'Time Breakdown'
    end
  end

  def status_badge_class(status)
    "ts-status-badge"
  end

  # Converts a #RRGGBB (or #RGB) hex string to an rgba() string. Mirrors the
  # `hexToRgba` JS helper used on the Visualize tab so tinted share badges look
  # identical across the My Time / My Team / Visualize pages.
  def ta_hex_to_rgba(hex, alpha = 1.0)
    c = hex.to_s.delete('#').strip
    c = c.chars.map { |ch| ch * 2 }.join if c.length == 3
    return "rgba(100,116,139,#{alpha})" unless c.length == 6

    r = c[0, 2].to_i(16)
    g = c[2, 2].to_i(16)
    b = c[4, 2].to_i(16)
    "rgba(#{r},#{g},#{b},#{alpha})"
  end

  # Renders the Visualize-style "share" pill: a rounded badge with a tinted
  # background and series-coloured text (e.g. the SHARE column on the Visualize
  # tab). Reused for the percentage column on the My Time / My Team summary tables.
  def ta_share_badge(hex, percentage)
    content_tag(:span, "#{number_with_precision(percentage, precision: 1)}%",
                class: 'inline-block rounded-full px-2.5 py-0.5 text-xs font-semibold',
                style: "background:#{ta_hex_to_rgba(hex, 0.14)};color:#{hex};")
  end
end
