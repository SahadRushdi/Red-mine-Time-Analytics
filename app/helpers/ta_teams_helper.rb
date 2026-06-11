module TaTeamsHelper
  TA_TEAM_BRANCH_COLORS = ['#B3E2CD', '#FDCDAC', '#CBD5E8', '#F4CAE4', '#E6F5C9', '#FFF2AE', '#F1E2CC', '#CCCCCC'].freeze

  def ta_team_tree(teams, level = 0, children_map = nil, active_member_counts = nil, open_hiring_counts = nil, team_memberships_map = nil)
    children_map ||= {}
    active_member_counts ||= {}
    open_hiring_counts ||= {}
    team_memberships_map ||= {}

    html = ''.html_safe
    teams.each do |team|
      team_memberships = Array(team_memberships_map[team.id]).select { |membership| membership.user.present? }
      members_panel_id = "ta-team-members-#{team.id}"
      child_teams = children_map[team.id] || []

      branch_content = ''.html_safe
      branch_content << content_tag(:div,
                                   class: "ta-team-item ta-team-dropzone level-#{level}",
                                   style: ta_team_item_style(level),
                                   data: { team_id: team.id, team_name: team.name },
                                   ondragover: 'teamManagementHandleDragOver(event)',
                                   ondragleave: 'teamManagementHandleDragLeave(event)',
                                   ondrop: 'teamManagementHandleDrop(event)') do
        left_content = ''.html_safe
        left_content << content_tag(:span, team.name, class: 'ta-team-name')
        member_count = active_member_counts[team.id].to_i
        left_content << content_tag(:span, member_count.to_s, class: 'ta-team-count-badge')

        open_hires = open_hiring_counts[team.id].to_i
        if open_hires.positive?
          left_content << content_tag(:span, "#{open_hires} hiring", class: 'ta-team-hiring-badge')
        end

        if team_memberships.any?
          left_content << content_tag(
            :button,
            content_tag(:span, 'Toggle members', class: 'sr-only') +
            '<svg class="w-4 h-4 text-gray-400 inline-block transition-transform duration-200 ta-team-member-toggle-icon" data-ta-member-toggle-icon="true" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"></path></svg>'.html_safe,
            type: 'button',
            class: 'ta-team-member-toggle',
            data: { collapse_toggle: members_panel_id, ta_member_toggle: 'true' },
            aria: { expanded: 'false', controls: members_panel_id }
          )
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
        right_links << content_tag(
          :button,
          content_tag(:span, ta_team_action_icon('members') + 'Add Member'.html_safe, class: 'ta-team-action-content'),
          type: 'button',
          class: 'ta-team-action ta-team-action-members',
          onclick: "teamManagementOpenAddMemberModal(#{team.id}, #{team.name.to_json})"
        )
        right_links << link_to(
          content_tag(:span, ta_team_action_icon('projects') + 'Projects'.html_safe, class: 'ta-team-action-content'),
          admin_ta_team_team_projects_path(team),
          class: 'ta-team-action ta-team-action-projects'
        )

        team_row = content_tag(:div, class: 'ta-team-row') do
          left = content_tag(:div, left_content, class: 'ta-team-left')
          right = content_tag(:div, right_links, class: 'ta-team-right')
          left + right
        end

        if team_memberships.empty?
          team_row
        else
          member_chips = team_memberships.map { |membership| ta_team_member_chip(team, membership) }
          members_panel = content_tag(:div, class: 'ta-team-members-panel hidden', id: members_panel_id) do
            content_tag(:div, safe_join(member_chips), class: 'ta-team-members-list')
          end

          team_row + members_panel
        end
      end

      if child_teams.any?
        branch_content << content_tag(:div, class: "ta-team-children level-#{level + 1}", style: ta_team_branch_style(level + 1)) do
          ta_team_tree(child_teams, level + 1, children_map, active_member_counts, open_hiring_counts, team_memberships_map)
        end
      end

      html << content_tag(:div, branch_content, class: "ta-team-branch level-#{level}")
    end
    html
  end

  def ta_team_member_chip(team, membership)
    user = membership.user
    return ''.html_safe unless user

    tooltip_id = "ta-team-member-tooltip-#{team.id}-#{user.id}"
    display_name = user.firstname.presence || user.name
    role_label = membership.lead? ? 'Team Lead' : 'Member'
    chip_classes = 'ta-team-member-chip '
    chip_classes += membership.lead? ? 'ta-team-member-chip--lead' : 'ta-team-member-chip--member'

    trigger = content_tag(
      :button,
      content_tag(:span, ta_user_initials(user), class: 'ta-team-member-initials') +
      content_tag(:span, h(display_name), class: 'ta-team-member-label') +
      (membership.lead? ? content_tag(:span, ta_team_lead_icon, class: 'ta-team-member-lead-icon') : ''.html_safe),
      type: 'button',
      class: chip_classes,
      draggable: 'true',
      data: {
        tooltip_target: tooltip_id,
        tooltip_placement: 'top',
        membership_id: membership.id,
        user_id: user.id,
        user_name: user.name,
        team_id: team.id,
        team_name: team.name,
        start_date: membership.start_date&.strftime('%m/%d/%Y') || ''
      },
      ondragstart: 'teamManagementHandleDragStart(event)'
    )

    tooltip = content_tag(:div, id: tooltip_id, role: 'tooltip', class: 'ta-team-member-tooltip absolute z-10 invisible opacity-0 tooltip') do
      content_tag(:div, class: 'ta-team-member-tooltip-content') do
        content_tag(:div, h(user.name), class: 'ta-team-member-tooltip-name') +
        content_tag(:div, h(user.mail), class: 'ta-team-member-tooltip-email') +
        content_tag(:div, role_label, class: 'ta-team-member-tooltip-role')
      end + content_tag(:div, ''.html_safe, class: 'tooltip-arrow', data: { popper_arrow: true })
    end

    content_tag(:div, trigger + tooltip, class: 'ta-team-member-chip-wrap')
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

  # Team-specific grouping options (Daily, Weekly, Month)
  def team_grouping_options
    [
      [l(:label_team_grouping_daily), 'daily'],
      [l(:label_team_grouping_weekly), 'weekly'],
      [l(:label_team_grouping_monthly), 'monthly']
    ]
  end

  def team_grouping_label(grouping)
    case grouping
    when 'daily'
      l(:label_team_grouping_daily)
    when 'monthly'
      l(:label_team_grouping_monthly)
    else
      l(:label_team_grouping_weekly)
    end
  end

  def ta_team_action_icon(type)
    case type
    when 'view'
      '<svg class="ta-team-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5s8.268 2.943 9.542 7c-1.274 4.057-5.065 7-9.542 7S3.732 16.057 2.458 12z"></path></svg>'.html_safe
    when 'edit'
      '<svg class="ta-team-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.5 2.5a2.121 2.121 0 013 3L12 15l-4 1 1-4 9.5-9.5z"></path></svg>'.html_safe
    when 'members'
      '<svg class="ta-team-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a4 4 0 00-5.356-3.768"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 20H4v-2a4 4 0 015.356-3.768"></path><circle cx="12" cy="7" r="4" stroke-width="2"></circle></svg>'.html_safe
    else
      '<svg class="ta-team-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10"></path></svg>'.html_safe
    end
  end

  def ta_team_lead_icon
    '<svg fill="currentColor" viewBox="0 0 20 20"><path d="M5 3.5a.5.5 0 01.786-.41L10 6l4.214-2.91A.5.5 0 0115 3.5V8a2 2 0 01-2 2h-1.27l.55 3.3a.5.5 0 01-.493.7H8.213a.5.5 0 01-.493-.7L8.27 10H7a2 2 0 01-2-2V3.5zM7 15a1 1 0 100 2h6a1 1 0 100-2H7z"></path></svg>'.html_safe
  end

  def ta_user_initials(user)
    parts = user.name.to_s.split(/\s+/).reject(&:blank?)
    initials = parts.first(2).map { |part| part[0] }.join.upcase
    initials.presence || user.name.to_s[0].to_s.upcase
  end

  def ta_team_branch_style(level)
    color = ta_team_branch_color(level)
    dark_color = ta_team_branch_darker_color(color)
    "--ta-team-branch-color: #{color}; --ta-team-branch-color-dark: #{dark_color};"
  end

  def ta_team_item_style(level)
    color = ta_team_branch_color(level)
    dark_color = ta_team_branch_darker_color(color, 0.34)
    light_color = ta_team_branch_tint(color, 0.24)
    lighter_color = ta_team_branch_tint(color, 0.14)
    shadow_color = ta_team_branch_tint(color, 0.16)
    "--ta-team-item-color: #{color}; --ta-team-item-border-dark: #{dark_color}; --ta-team-item-bg: #{lighter_color}; --ta-team-item-bg-hover: #{light_color}; --ta-team-item-shadow: #{shadow_color};"
  end

  def ta_team_branch_color(level)
    TA_TEAM_BRANCH_COLORS[level.to_i % TA_TEAM_BRANCH_COLORS.length]
  end

  def ta_team_branch_darker_color(hex_color, factor = 0.18)
    hex = hex_color.delete_prefix('#')
    return hex_color unless hex.match?(/\A[0-9a-fA-F]{6}\z/)

    channels = [hex[0..1], hex[2..3], hex[4..5]].map { |channel| channel.to_i(16) }
    darker = channels.map { |channel| [(channel * (1 - factor)).round, 0].max }

    format('#%02X%02X%02X', *darker)
  end

  def ta_team_branch_tint(hex_color, alpha)
    hex = hex_color.delete_prefix('#')
    return hex_color unless hex.match?(/\A[0-9a-fA-F]{6}\z/)

    red = hex[0..1].to_i(16)
    green = hex[2..3].to_i(16)
    blue = hex[4..5].to_i(16)
    "rgba(#{red}, #{green}, #{blue}, #{alpha})"
  end
end
