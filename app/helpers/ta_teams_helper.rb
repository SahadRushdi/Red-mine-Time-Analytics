module TaTeamsHelper
  def ta_team_tree(teams, level = 0, children_map = nil, active_member_counts = nil, open_hiring_counts = nil)
    children_map ||= {}
    active_member_counts ||= {}
    open_hiring_counts ||= {}

    html = ''.html_safe
    teams.each do |team|
      html << content_tag(:div, class: "ta-team-item ta-team-dropzone level-#{level}", data: { team_id: team.id }) do
        left_content = ''.html_safe
        left_content << content_tag(:span, team.name, class: 'ta-team-name')
        member_count = active_member_counts[team.id].to_i
        left_content << content_tag(:span, member_count.to_s, class: 'ta-team-count-badge')

        open_hires = open_hiring_counts[team.id].to_i
        if open_hires.positive?
          left_content << content_tag(:span, "#{open_hires} hiring", class: 'ta-team-hiring-badge')
        end

        right_links = ''.html_safe
        right_links << link_to(
          content_tag(:span, ta_team_action_icon('view') + 'View'.html_safe, class: 'ta-team-action-content'),
          admin_ta_team_path(team),
          class: 'ta-team-action ta-team-action-view'
        )
        right_links << link_to(
          content_tag(:span, ta_team_action_icon('edit') + 'Edit'.html_safe, class: 'ta-team-action-content'),
          edit_admin_ta_team_path(team),
          class: 'ta-team-action ta-team-action-edit'
        )
        right_links << link_to(
          content_tag(:span, ta_team_action_icon('delete') + 'Delete'.html_safe, class: 'ta-team-action-content'),
          admin_ta_team_path(team),
          method: :delete,
          data: { confirm: 'Are you sure?' },
          class: 'ta-team-action ta-team-action-delete'
        )
        right_links << link_to(
          content_tag(:span, ta_team_action_icon('members') + 'Members'.html_safe, class: 'ta-team-action-content'),
          admin_ta_team_memberships_path(team),
          class: 'ta-team-action ta-team-action-members'
        )
        right_links << link_to(
          content_tag(:span, ta_team_action_icon('projects') + 'Projects'.html_safe, class: 'ta-team-action-content'),
          admin_ta_team_team_projects_path(team),
          class: 'ta-team-action ta-team-action-projects'
        )

        content_tag(:div, class: 'ta-team-row') do
          left = content_tag(:div, left_content, class: 'ta-team-left')
          right = content_tag(:div, right_links, class: 'ta-team-right')
          left + right
        end
      end
      child_teams = children_map[team.id] || []
      if child_teams.any?
        html << ta_team_tree(child_teams, level + 1, children_map, active_member_counts, open_hiring_counts)
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

  def ta_team_action_icon(type)
    case type
    when 'view'
      '<svg class="ta-team-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5s8.268 2.943 9.542 7c-1.274 4.057-5.065 7-9.542 7S3.732 16.057 2.458 12z"></path></svg>'.html_safe
    when 'edit'
      '<svg class="ta-team-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.5 2.5a2.121 2.121 0 013 3L12 15l-4 1 1-4 9.5-9.5z"></path></svg>'.html_safe
    when 'delete'
      '<svg class="ta-team-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6M9 7V4a1 1 0 011-1h4a1 1 0 011 1v3M4 7h16"></path></svg>'.html_safe
    when 'members'
      '<svg class="ta-team-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a4 4 0 00-5.356-3.768"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 20H4v-2a4 4 0 015.356-3.768"></path><circle cx="12" cy="7" r="4" stroke-width="2"></circle></svg>'.html_safe
    else
      '<svg class="ta-team-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10"></path></svg>'.html_safe
    end
  end
end
