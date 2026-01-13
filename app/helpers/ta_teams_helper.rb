module TaTeamsHelper
  def ta_team_tree(teams, level = 0)
    html = ''.html_safe
    teams.each do |team|
      html << content_tag(:div, class: "ta-team-item level-#{level}") do
        content = ''.html_safe
        content << content_tag(:span, team.name, class: 'ta-team-name')
        content << content_tag(:span, "(#{team.current_members.count} members)", class: 'ta-team-member-count')
        content << link_to('View', admin_ta_team_path(team), class: 'icon icon-zoom-in')
        content << link_to('Edit', edit_admin_ta_team_path(team), class: 'icon icon-edit')
        content << link_to('Delete', admin_ta_team_path(team), method: :delete, 
                          data: { confirm: 'Are you sure?' }, class: 'icon icon-del')
        content << link_to('Members', admin_ta_team_memberships_path(team), class: 'icon icon-user')
        content << link_to('Projects', admin_ta_team_team_projects_path(team), class: 'icon icon-projects')
        content
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
end
