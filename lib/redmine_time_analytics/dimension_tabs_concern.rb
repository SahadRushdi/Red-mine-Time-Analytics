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
      helper_method :ta_dimension, :ta_dimension_view_state, :ta_dimension_summary_payload,
                    :ta_grouped_hours_label, :ta_grouped_hours_note
    end

    # --- Actions -----------------------------------------------------------------------------

    # Feeds the "+" picker. Routed separately on each dashboard so it inherits that controller's
    # own before_action chain and access checks.
    def groupable_fields
      response.headers['Cache-Control'] = 'no-store'
      render json: { sections: GroupableFieldRegistry.picker_payload(User.current) }
    end

    # Lazy-loaded issue-level breakdown for one group value, so a Summary row on a dynamic tab
    # expands the same way the Project and Activity rows do. Mirrors the existing
    # issue_breakdown response shape exactly, so ta_client_table.js consumes it unchanged.
    def group_breakdown
      field = GroupableFieldRegistry.find(params[:group_by], User.current)
      return render json: { error: 'Unknown field' }, status: 404 unless field

      base_scope = ta_dimension_scope
      return render json: { error: 'Unauthorized' }, status: 403 unless base_scope

      permitted = params.permit(:group_by, :group_value, :no_value)
      raw_value = permitted[:no_value].to_s == '1' ? nil : permitted[:group_value]
      scope = DimensionPivot.scope_for_value(base_scope, field, raw_value)

      issue_totals = scope.reorder(nil).group(:issue_id).sum(:hours)
      issues = Issue.visible(User.current).where(id: issue_totals.keys.compact)
                    .includes(:tracker, :assigned_to).index_by(&:id)
      explanations = field.multiple? ? ta_multiple_value_explanations(base_scope, field, issue_totals.keys, issues.keys) : {}
      if field.multiple?
        # Do not expose inaccessible issue identifiers. Entries without a visible issue still
        # need an aggregate row so the expanded hours reconcile with their parent group.
        issue_totals = issue_totals.each_with_object(Hash.new(0.0)) do |(id, hours), totals|
          totals[issues.key?(id) ? id : nil] += hours.to_f
        end
      end

      items = issue_totals.filter_map do |issue_id, hours|
        issue = issues[issue_id]
        next unless issue || (field.multiple? && issue_id.nil?)

        item = {
          id: issue&.id,
          subject: issue ? issue.subject : l(:label_ta_no_issue),
          trackerName: issue&.tracker&.name,
          url: issue ? issue_path(issue) : nil,
          hours: hours.to_f,
          assigneeName: issue&.assigned_to&.name
        }
        item.merge(explanations.fetch(issue_id, {}))
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

    def ta_grouped_hours_label
      @ta_dimension&.multiple? ? l(:label_ta_hours_across_field, field: @ta_dimension.label) : l(:label_ta_total_hours)
    end

    def ta_grouped_hours_note
      return unless @ta_dimension&.multiple?

      l(:text_ta_multiple_value_context, hours: helpers.format_hours(@ta_dimension_pivot[:logged_total]))
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
      ta_apply_multiple_value_statistics! if @ta_dimension.multiple?

      # export_csv reuses this builder without setting up pagination, so both are defaulted here
      # rather than assumed.
      offset = @offset || 0
      limit  = @limit.to_i.positive? ? @limit : 25
      @paginated_periods = @time_periods.slice(offset, limit) || []
      @total_pages = (@entry_count.to_f / limit).ceil
      @ta_dimension_view_state = params[:dim_view_state].presence || 'summary'
    end

    # Reuse each dashboard's existing denominators, zero-filled periods and leave rules.
    # Only the source of hours changes; issue/member/day counts remain based on real entries.
    def ta_apply_multiple_value_statistics!
      @total_hours = @ta_dimension_pivot[:grand_total]
      return unless @active_days_count

      original_entries = @time_entries
      begin
        @time_entries = DimensionPivot.apply_joins(original_entries, @ta_dimension)
        if respond_to?(:generate_time_overview_data, true)
          @time_overview_data = generate_time_overview_data(@time_entries, @grouping,
                                                         period_totals: @ta_dimension_pivot[:period_totals])
          @overview_total_pages = (@time_overview_data.count.to_f / @overview_limit).ceil
        end
        unit = { 'daily' => 'day', 'weekly' => 'week', 'monthly' => 'month', 'yearly' => 'year' }.fetch(@grouping, 'day')
        average_method = "calculate_avg_hours_per_#{unit}"
        @avg_hours_per_period = send(average_method) if respond_to?(average_method, true)
        %w[max min].each do |stat|
          method = "calculate_#{stat}_#{@grouping}_hours"
          next unless respond_to?(method, true)

          value = send(method)
          instance_variable_set("@#{stat}_period_hours", value.is_a?(Array) ? value.first : value)
        end
      ensure
        @time_entries = original_entries
      end
    end

    # Three batched lookups, not one query per issue. For time-entry custom fields the same
    # issue can have different selections on different entries, so calculate each contribution
    # from its joined time entries rather than multiplying an issue total by a selection count.
    def ta_multiple_value_explanations(base_scope, field, issue_ids, visible_ids)
      entries = base_scope.where(issue_id: issue_ids).except(:includes, :eager_load, :preload, :order)
      logged = entries.group(:issue_id).sum(:hours)
      contributions = DimensionPivot.apply_joins(entries, field).group(:issue_id, field.group_sql).sum(:hours)
      names = DimensionPivot.label_map(field, contributions.keys.map(&:last).uniq, l(:label_ta_no_value))
      result = {}
      logged.each do |id, hours|
        key = visible_ids.include?(id) ? id : nil
        result[key] ||= { loggedHours: 0.0, groupedHours: 0.0, valueBreakdown: [] }
        result[key][:loggedHours] += hours.to_f
      end
      contributions.each do |(id, raw), hours|
        key = visible_ids.include?(id) ? id : nil
        item = result.fetch(key)
        name = names[DimensionPivot.normalize(raw)]
        value = item[:valueBreakdown].find { |row| row[:name] == name }
        if value
          value[:hours] += hours.to_f
        else
          item[:valueBreakdown] << { name: name, hours: hours.to_f }
        end
        item[:groupedHours] += hours.to_f
      end
      result
    end

    # The JSON the Summary cards and the donut are both rendered from, matching the payload shape
    # the pinned tabs emit.
    def ta_dimension_summary_payload
      pivot = @ta_dimension_pivot
      {
        grandTotal: pivot[:grand_total].to_f,
        loggedTotal: pivot[:logged_total].to_f,
        countingMode: pivot[:counting_mode],
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
        total_label = @ta_dimension.multiple? ? l(:label_ta_hours_across_field, field: @ta_dimension.label) : 'TOTAL'
        csv << [total_label, helpers.format_hours(pivot[:grand_total])]
        if @ta_dimension.multiple?
          csv << [l(:label_ta_actual_logged_hours), helpers.format_hours(pivot[:logged_total])]
          csv << [l(:text_ta_multiple_value_counting)]
        end
      end
    end
  end
end
