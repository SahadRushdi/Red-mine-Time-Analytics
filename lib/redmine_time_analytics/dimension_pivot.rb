module RedmineTimeAnalytics
  # Builds a period x dimension pivot for any GroupableFieldRegistry::Field, in exactly the shape
  # the pinned tabs' builders produce (generate_activity_pivot_table / generate_project_pivot_table),
  # so the existing pivot partial, Summary payload and donut code consume it unchanged.
  #
  # The per-bucket SUM(:hours) work is delegated back to the calling controller's own bucket
  # helpers, so there is one definition of "how a period bucket is summed" per dashboard and this
  # class never duplicates it.
  module DimensionPivot
    # Sentinel for "no value": a time entry with no issue, an issue with no value for the field,
    # or a value hidden from this user by the custom field's own visibility SQL. All of them are
    # one bucket.
    NONE_KEY = :__ta_none__

    # Mirrors TimeEntry.left_join_issue (app/models/time_entry.rb). Used as a raw string join
    # rather than the scope so that it and the custom-field join are both string joins, which
    # ActiveRecord emits in the order given — the IssueCustomField join references issues.project_id
    # via CustomField#visibility_by_project_condition, so issues MUST be joined first.
    def self.left_join_issue_sql
      "LEFT OUTER JOIN #{Issue.table_name}" \
        " ON #{Issue.table_name}.id = #{TimeEntry.table_name}.issue_id" \
        " AND (#{Issue.visible_condition(User.current)})"
    end

    # Both dashboards build @time_entries with .includes(...) and .order(...). Neither survives a
    # GROUP BY: PostgreSQL rejects an ORDER BY on a non-grouped column, and `includes` would flip
    # into eager_load and add real join fan-out. Strip both before grouping.
    def self.apply_joins(scope, field)
      scope = scope.except(:includes, :eager_load, :preload, :order)
      scope = scope.joins(left_join_issue_sql) if field.needs_issue_join
      scope = scope.joins(field.join_sql) if field.join_sql.present?
      scope
    end

    # period_totals_fn   -> ->(scope, grouping)          { {period_key => hours} }
    # category_totals_fn -> ->(scope, grouping, column)  { {period_key => {raw_value => hours}} }
    # period_display_fn  -> ->(period_key)               { "October 2025" }
    def self.build(scope:, field:, grouping:, period_totals_fn:, category_totals_fn:,
                   period_display_fn:, none_label:)
      assert_join_budget!(field)

      joined = apply_joins(scope, field)

      period_totals   = period_totals_fn.call(joined, grouping)
      hours_by_period = category_totals_fn.call(joined, grouping, field.group_sql)

      # Most recent period first, matching the pinned tabs' tables.
      raw_periods = period_totals.keys.sort.reverse

      # One SQL SUM for the per-dimension totals rather than accumulating the per-bucket hashes in
      # Ruby, so the Summary numbers line up exactly with Total Hours (same reasoning as the
      # comment on TimeAnalyticsController#sql_bucket_hours_totals).
      raw_totals  = joined.reorder(nil).group(field.group_sql).sum(:hours)
      grand_total = joined.reorder(nil).sum(:hours)

      raw_values = (raw_totals.keys + hours_by_period.values.flat_map(&:keys)).uniq
      labels = label_map(field, raw_values, none_label)

      matrix = {}
      raw_periods.each do |period|
        cells = {}
        (hours_by_period[period] || {}).each do |raw, hours|
          name = labels[normalize(raw)]
          cells[name] = (cells[name] || 0) + hours.to_f
        end
        matrix[period] = cells
      end

      category_totals = Hash.new(0.0)
      category_values = {}
      raw_totals.each do |raw, hours|
        key  = normalize(raw)
        name = labels[key]
        category_totals[name] += hours.to_f
        # The raw value behind each display name, so a Summary row can ask group_breakdown for
        # exactly this group. nil marks the no-value bucket.
        category_values[name] = (key == NONE_KEY ? nil : raw)
      end

      categories = category_totals.keys.sort_by { |name| -category_totals[name] }

      {
        periods: raw_periods.map { |period| period_display_fn.call(period) },
        categories: categories,
        matrix: matrix,
        period_totals: period_totals,
        category_totals: category_totals,
        category_values: category_values,
        grand_total: grand_total,
        raw_periods: raw_periods
      }
    end

    # Restricts a scope to a single group value, for the row drill-down and the CSV export.
    # `raw_value` is nil for the no-value bucket.
    def self.scope_for_value(scope, field, raw_value)
      joined = apply_joins(scope, field)

      if raw_value.blank?
        joined.where("#{field.group_sql} IS NULL OR #{field.group_sql} = ''")
      else
        joined.where("#{field.group_sql} = ?", raw_value.to_s)
      end
    end

    def self.normalize(raw)
      raw.nil? || raw.to_s.strip.empty? ? NONE_KEY : raw
    end

    # Resolves every distinct raw value to a display label in one batched lookup, never per row.
    def self.label_map(field, raw_values, none_label)
      present = raw_values.reject { |raw| normalize(raw) == NONE_KEY }
      resolved = field.resolver ? field.resolver.call(present) : {}

      map = { NONE_KEY => none_label }
      present.each { |raw| map[raw] = resolved[raw].presence || raw.to_s }
      map
    end

    # One tab groups by exactly one dimension, so this holds structurally today. Asserted so that
    # any future nested/cross grouping can't silently multiply the custom_values joins.
    def self.assert_join_budget!(field)
      joins = field.join_sql.present? ? 1 : 0
      return if joins <= GroupableFieldRegistry::MAX_CUSTOM_FIELD_JOINS

      raise ArgumentError, "too many custom field joins for one grouped query (#{joins})"
    end
  end
end
