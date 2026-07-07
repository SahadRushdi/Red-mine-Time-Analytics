# frozen_string_literal: true

module RedmineTimeAnalytics
  # Injects the "Manage groups" button + board modal onto Redmine core's Administration ->
  # Enumerations page (next to the "Activities (time tracking)" section), replacing the plugin's
  # former dedicated "Activity Groups" admin page. Core's app/views/enumerations/index.html.erb
  # has no call_hook points of its own, so this listens on the generic base-layout hooks (fired on
  # every page) and only renders when the current request is EnumerationsController#index.
  class ActivityGroupsHook < Redmine::Hook::ViewListener
    def view_layouts_base_html_head(context = {})
      return '' unless enumerations_index?(context)

      stylesheet_link_tag('flowbite.min.css', plugin: 'redmine_time_analytics') +
        stylesheet_link_tag('tailwind.output.css', plugin: 'redmine_time_analytics') +
        stylesheet_link_tag('team_management.css', plugin: 'redmine_time_analytics') +
        javascript_include_tag('flowbite.min.js', plugin: 'redmine_time_analytics') +
        javascript_include_tag('ta_activity_group_board.js', plugin: 'redmine_time_analytics') +
        '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,400,0,0" />'.html_safe
    end

    def view_layouts_base_body_bottom(context = {})
      return '' unless enumerations_index?(context)

      context[:controller].send(
        :render_to_string,
        partial: 'admin_ta_activity_groups/manage_groups_modal',
        locals: {
          groups: TaActivityGroup.ordered.to_a,
          activities: TimeEntryActivity.shared.sorted.to_a,
          assignments: TaActivityGroupAssignment.pluck(:activity_id, :group_id).to_h
        }
      )
    end

    private

    def enumerations_index?(context)
      controller = context[:controller]
      controller && controller.controller_name == 'enumerations' && controller.action_name == 'index'
    end
  end
end
