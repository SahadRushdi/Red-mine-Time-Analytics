module TaTeamsHelper
  def ta_team_tree(teams, level = 0)
    html = ''.html_safe
    teams.each do |team|
      html << content_tag(:div, class: "ta-team-item level-#{level}") do
        left_content = ''.html_safe
        left_content << content_tag(:span, team.name, class: 'ta-team-name')
        left_content << content_tag(:span, "#{team.current_members.count}", class: 'ta-team-count-badge')

        open_hires = team.ta_hiring_needs.open.count
        if open_hires.positive?
          left_content << content_tag(:span, "#{open_hires} hiring", class: 'ta-team-hiring-badge')
        end

        right_links = ''.html_safe
        right_links << link_to('View', admin_ta_team_path(team), class: 'ta-team-action ta-team-action-view')
        right_links << link_to('Edit', edit_admin_ta_team_path(team), class: 'ta-team-action ta-team-action-edit')
        right_links << link_to('Delete', admin_ta_team_path(team), method: :delete,
                               data: { confirm: 'Are you sure?' }, class: 'ta-team-action ta-team-action-delete')
        right_links << link_to('Members', admin_ta_team_memberships_path(team), class: 'ta-team-action ta-team-action-members')
        right_links << link_to('Projects', admin_ta_team_team_projects_path(team), class: 'ta-team-action ta-team-action-projects')

        content_tag(:div, class: 'ta-team-row') do
          left = content_tag(:div, left_content, class: 'ta-team-left')
          right = content_tag(:div, right_links, class: 'ta-team-right')
          left + right
        end
      end
      # Recursively render child teams
      if team.child_teams.any?
        html << ta_team_tree(team.child_teams.ordered_by_name, level + 1)
      end
    end
    html
  end

  def ta_team_breadcrumb(team)
    ancestors = team.all_ancestors.reverse
    links = ancestors.map { |t| link_to(t.name, admin_ta_team_path(t)) }
    links << content_tag(:strong, team.name)
    safe_join(links, ' &raquo; '.html_safe)
  end

  def role_options_for_select(selected = nil)
    options_for_select([
      ['Team Lead', 'lead'],
      ['Team Member', 'member']
    ], selected)
  end

  def ta_team_select_options(selected = nil, exclude_ids = [])
    teams = TaTeam.ordered_by_name
    teams = teams.where.not(id: exclude_ids) if exclude_ids.any?
    
    grouped_options = [[l(:label_none), '']]
    teams.each do |team|
      level = team.all_ancestors.count
      indent = '&nbsp;&nbsp;' * level
      label = "#{indent}#{team.name}".html_safe
      grouped_options << [label, team.id]
    end
    
    options_for_select(grouped_options, selected)
  end

  # Team-specific time filter options (different from Individual Dashboard)
  def team_time_filter_options
    [
      [l(:label_this_month), 'this_month'],
      [l(:label_last_month), 'last_month'],
      ['Last 3 Months', 'last_3_months'],
      [l(:label_custom_range), 'custom']
    ]
  end

  # Team-specific grouping options (only Week and Month)
  def team_grouping_options
    [
      [l(:label_weekly), 'weekly'],
      [l(:label_monthly), 'monthly']
    ]
  end
end
