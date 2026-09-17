module RedmineTimeAnalytics
  # The shared half of the "group by" tabs: everything both dashboards do identically once a
  # dimension has been picked. Included by TimeAnalyticsController and TeamAnalyticsController.
  #
  # Each host controller supplies four small hooks, so no bucketing or scoping logic is
  # duplicated here:
  #   ta_dim_period_totals(scope, grouping)           -> its own Date-keyed period bucketer
  #   ta_dim_category_totals(scope, grouping, column) -> the same, further grouped by a column
  #   ta_dimension_scope                              -> the base time-entry scope for drill-downs
  #   ta_dimension_default_view_mode                  -> the pinned tab to fall back to
  #
  # NOTE on the bucket hooks: TeamAnalyticsController has *two* bucketers with different key
  # semantics — pivot_bucket_hours_totals (Date keys, feeds the pivot tables) and
  # sql_bucket_hours_totals (monthly keyed as [year, month], feeds Max/Min Month and the Time
  # Overview table). The hooks must always be wired to the Date-keyed `pivot_*` pair there.
  module DimensionTabsConcern
    extend ActiveSupport::Concern

    included do
      helper_method :ta_dimension, :ta_dimension_view_state, :ta_dimension_summary_payload
    end

    # --- Actions -----------------------------------------------------------------------------

    # Feeds the "+" picker. Routed separately on each dashboard so it inherits that controller's
    # own before_action chain and access checks.
    def groupable_fields
      render json: { sections: GroupableFieldRegistry.picker_payload(User.current) }
    end

    # Lazy-loaded issue-level breakdown for one group value, so a Summary row on a dynamic tab
    # expands the same way the Project and Activity rows do. Mirrors the existing
    # issue_breakdown response shape exactly, so ta_client_table.js consumes it unchanged.
    def group_breakdown
      field = GroupableFieldRegistry.find(params[:group_by], User.current)
      return render json: { error: 'Unknown field' }, status: 404 unless field

      scope = ta_dimension_scope
      return render json: { error: 'Unauthorized' }, status: 403 unless scope

      permitted = params.permit(:group_by, :group_value, :no_value)
      raw_value = permitted[:no_value].to_s == '1' ? nil : permitted[:group_value]
      scope = DimensionPivot.scope_for_value(scope, field, raw_value)

      issue_totals = scope.reorder(nil).group(:issue_id).sum(:hours)
                          .reject { |issue_id, _| issue_id.nil? }
      issues = Issue.where(id: issue_totals.keys).includes(:tracker, :assigned_to).index_by(&:id)

      items = issue_totals.filter_map do |issue_id, hours|
        issue = issues[issue_id]
        next unless issue

        {
          id: issue.id,
          subject: issue.subject,
          trackerName: issue.tracker&.name,
          url: issue_path(issue),
          hours: hours.to_f,
          assigneeName: issue.assigned_to&.name
        }
      end.sort_by { |item| -item[:hours] }

      render json: { grandTotal: items.sum { |item| item[:hours] }, items: items }
    end

    # --- View construction -------------------------------------------------------------------

    def ta_dimension
      @ta_dimension
    end

    def ta_dimension_view_state
      @ta_dimension_view_state
    end

    private

    # True when the current view_mode names a dimension this user may group by. Returns false for
    # the pinned tabs so the existing branch chain is completely unaffected.
    def ta_resolve_dimension!
      return false unless GroupableFieldRegistry.dimension?(@view_mode)

      @ta_dimension = GroupableFieldRegistry.find(@view_mode, User.current)
      @ta_dimension.present?
    end

    # A view_mode that looks like a dimension but no longer resolves (field deleted, un-ticked as
    # a filter, or hidden from this user's roles) must not 404 — it bounces back to the default
    # tab and tells the client to prune it from sessionStorage.
    def ta_invalid_dimension?
      GroupableFieldRegistry.dimension?(@view_mode) &&
        GroupableFieldRegistry.find(@view_mode, User.current).nil?
    end

    def ta_build_dimension_view!
      @ta_dimension_pivot = DimensionPivot.build(
        scope: @time_entries,
        field: @ta_dimension,
        grouping: @grouping,
        period_totals_fn: ->(scope, grouping) { ta_dim_period_totals(scope, grouping) },
        category_totals_fn: ->(scope, grouping, column) { ta_dim_category_totals(scope, grouping, column) },
        period_display_fn: ->(key) { format_activity_period_display(key, @grouping) },
        none_label: l(:label_ta_no_value)
      )

      @time_periods    = @ta_dimension_pivot[:periods]
      @matrix_data     = @ta_dimension_pivot[:matrix]
      @period_totals   = @ta_dimension_pivot[:period_totals]
      @grand_total     = @ta_dimension_pivot[:grand_total]
      @entry_count     = @time_periods.count

      # export_csv reuses this builder without setting up pagination, so both are defaulted here
      # rather than assumed.
      offset = @offset || 0
      limit  = @limit.to_i.positive? ? @limit : 25
      @paginated_periods = @time_periods.slice(offset, limit) || []
      @total_pages = (@entry_count.to_f / limit).ceil
      @ta_dimension_view_state = params[:dim_view_state].presence || 'summary'
    end

    # The JSON the Summary cards and the donut are both rendered from, matching the payload shape
    # the pinned tabs emit.
    def ta_dimension_summary_payload
      pivot = @ta_dimension_pivot
      {
        grandTotal: pivot[:grand_total].to_f,
        items: pivot[:categories].map do |name|
          raw = pivot[:category_values][name]
          {
            name: name,
            hours: (pivot[:category_totals][name] || 0).to_f,
            groupValue: raw,
            noValue: raw.nil?
          }
        end
      }
    end

    # Matches the layout of export_activity_analysis_to_csv / export_project_analysis_to_csv
    # (header row, rows sorted by hours desc, blank line, TOTAL) so every export on these
    # dashboards reads the same.
    def ta_dimension_csv
      require 'csv'
      pivot = @ta_dimension_pivot

      CSV.generate(headers: true) do |csv|
        csv << [@ta_dimension.label, 'Total Hours']
        pivot[:categories].each do |name|
          csv << [name, helpers.format_hours(pivot[:category_totals][name] || 0)]
        end
        csv << []
        csv << ['TOTAL', helpers.format_hours(pivot[:grand_total])]
      end
    end
  end
end
