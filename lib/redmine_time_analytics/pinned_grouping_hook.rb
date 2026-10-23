# frozen_string_literal: true

module RedmineTimeAnalytics
  # Adds "Show as a grouping tab in Time Analytics" to Administration -> Custom fields, for the
  # two custom field types the dashboards can group by.
  #
  # Uses core's own hook points rather than patching CustomFieldsController:
  #   * view_custom_fields_form_<type>          renders the checkbox in the right-hand box, next
  #                                             to "Used as a filter" (core _form.html.erb:53)
  #   * controller_custom_fields_new_after_save
  #   * controller_custom_fields_edit_after_save persist it only once the field itself saved
  #
  # The checkbox is intentionally rendered *outside* params[:custom_field] (name
  # "ta_pinned_grouping"), so it can never collide with CustomField#safe_attributes.
  class PinnedGroupingHook < Redmine::Hook::ViewListener
    def view_layouts_base_html_head(context = {})
      controller = context[:controller]
      return '' unless controller && controller.controller_name == 'custom_fields'

      javascript_include_tag('ta_grouping_custom_fields.js', plugin: 'redmine_time_analytics')
    end

    def view_custom_fields_form_issue_custom_field(context = {})
      render_checkbox(context)
    end

    def view_custom_fields_form_time_entry_custom_field(context = {})
      render_checkbox(context)
    end

    def controller_custom_fields_new_after_save(context = {})
      persist(context)
    end

    def controller_custom_fields_edit_after_save(context = {})
      persist(context)
    end

    private

    def render_checkbox(context)
      custom_field = context[:custom_field]
      return '' unless groupable_type?(custom_field)

      checked = TaPinnedGrouping.pinned?(custom_field)
      supported = GroupableFieldRegistry.supported?(custom_field)
      eligible = GroupableFieldRegistry.eligible?(custom_field)

      # Built with the non-block tag helpers on purpose: a ViewListener has no output buffer, so
      # the `tag.p do ... end` block form raises NoMethodError (output_buffer=).
      #
      # The paired hidden field is what makes unticking actually submit, instead of the checkbox
      # just being absent from the params.
      parts = [
        hidden_field_tag('ta_pinned_grouping', '0', id: 'ta-pinned-grouping-unchecked', disabled: !eligible),
        check_box_tag('ta_pinned_grouping', '1', checked, disabled: !eligible),
        label_tag('ta_pinned_grouping', l(:label_ta_pinned_grouping)),
        content_tag(:em, l(:text_ta_pinned_grouping_requires_filter), class: 'info', hidden: eligible)
      ]

      content_tag(:p, safe_join(parts), id: 'ta-pinned-grouping-control', hidden: !supported,
                  data: { grouping_formats: GroupableFieldRegistry::GROUPABLE_CF_FORMATS.to_json })
    end

    def persist(context)
      params = context[:params]
      custom_field = context[:custom_field]
      return unless groupable_type?(custom_field)
      return unless params.key?(:ta_pinned_grouping) || params.key?('ta_pinned_grouping')
      # Keep existing pin intent while ineligible, but never create an unusable pin.
      return unless GroupableFieldRegistry.eligible?(custom_field)

      TaPinnedGrouping.set_pinned(custom_field, params[:ta_pinned_grouping].to_s == '1')
    end

    def groupable_type?(custom_field)
      custom_field.is_a?(IssueCustomField) || custom_field.is_a?(TimeEntryCustomField)
    end
  end
end
