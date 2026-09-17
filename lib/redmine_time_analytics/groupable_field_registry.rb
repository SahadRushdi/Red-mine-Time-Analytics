module RedmineTimeAnalytics
  # Data-driven registry of the dimensions a Time Analytics dashboard can group hours by,
  # beyond the pinned Issue/Activity/Project (individual) and Members/Activity/Project (team)
  # tabs.
  #
  # Two sources feed it:
  #   * STATIC_FIELDS — issue attributes reachable from time_entries via time_entries.issue_id.
  #   * Custom fields — TimeEntryCustomField (joined directly) and IssueCustomField (joined
  #     through issues), discovered at call time so a field an admin adds shows up with no
  #     plugin code change and no restart.
  #
  # Every entry knows the five things a grouped query needs: a stable key, a display label, its
  # join path, the SQL expression to GROUP BY, and how to turn a grouped raw value back into a
  # display label.
  #
  # The SQL is deliberately NOT hand-rolled for custom fields. CustomField#join_for_order_statement
  # already emits a LEFT OUTER JOIN that is role/project-visibility scoped, de-duplicated to at
  # most one custom_values row per record (`id = (SELECT max(...))`) and filtered to
  # `value <> ''` — so it can never inflate SUM(hours), and a blanked value falls into the
  # no-value bucket on its own.
  class GroupableFieldRegistry
    # Single-value formats only: a multi-value or long-text field doesn't produce a meaningful
    # group. bool/int/enumeration are also single-value and groupable in core — adding them is a
    # one-line change here.
    GROUPABLE_CF_FORMATS = %w[list string date user version].freeze

    # At most one custom-field join may be active in a single grouped query. One tab groups by
    # exactly one dimension, so this is structurally satisfied today; it is asserted in
    # DimensionPivot so that any future nested grouping can't silently fan out the joins.
    MAX_CUSTOM_FIELD_JOINS = 1

    # view_mode values owned by the pinned tabs. A dimension key can never collide with one.
    RESERVED_KEYS = %w[issue activity project members time_entries].freeze

    SECTION_ISSUE_ATTRIBUTE = :issue_attribute
    SECTION_TIME_ENTRY_CF   = :time_entry_cf
    SECTION_ISSUE_CF        = :issue_cf

    # key              — stable, URL-safe; survives renaming the underlying field
    # label            — display string
    # section          — picker grouping
    # group_sql        — the GROUP BY expression (Arel.sql-wrapped)
    # needs_issue_join — whether the scope must LEFT JOIN issues first
    # join_sql         — extra LEFT JOIN (custom fields only), or nil
    # custom_field     — the CustomField, or nil for static fields
    # resolver         — ->(raw_values) { {raw_value => display_label} }, batched
    Field = Struct.new(:key, :label, :section, :group_sql, :needs_issue_join,
                       :join_sql, :custom_field, :resolver, keyword_init: true) do
      # True when an administrator pinned this field as a permanent grouping tab
      # (see TaPinnedGrouping).
      def pinned?
        custom_field.present? && TaPinnedGrouping.pinned?(custom_field)
      end
    end

    # Issue attributes reachable through time_entries.issue_id -> issues.id.
    STATIC_FIELDS = [
      { key: 'issue_tracker',       label: :field_tracker,       column: 'issues.tracker_id',       model: 'Tracker' },
      { key: 'issue_status',        label: :field_status,        column: 'issues.status_id',        model: 'IssueStatus' },
      { key: 'issue_priority',      label: :field_priority,      column: 'issues.priority_id',      model: 'IssuePriority' },
      { key: 'issue_category',      label: :field_category,      column: 'issues.category_id',      model: 'IssueCategory' },
      { key: 'issue_fixed_version', label: :field_fixed_version, column: 'issues.fixed_version_id', model: 'Version' },
      { key: 'issue_author',        label: :field_author,        column: 'issues.author_id',        model: 'User' },
      { key: 'issue_assigned_to',   label: :field_assigned_to,   column: 'issues.assigned_to_id',   model: 'User' }
    ].freeze

    class << self
      # Every dimension this user may group by, static first then custom fields.
      def all(user = User.current)
        static_fields + custom_fields(user)
      end

      # Resolves a key coming off the URL. Always re-derived through `all`, so a field that has
      # been deleted, un-ticked as a filter, or hidden from this user's roles is unreachable even
      # via a hand-crafted link. Returns nil rather than raising.
      def find(key, user = User.current)
        key = key.to_s
        return nil unless dimension?(key)

        all(user).detect { |field| field.key == key }
      end

      # The fields an administrator pinned as permanent grouping tabs, in the order they were
      # pinned. A pin is only intent — a field that has since been un-ticked as a filter, hidden
      # from this user's roles, or changed to an ungroupable format simply drops out here, so a
      # stale pin can never render a broken tab.
      def pinned(user = User.current)
        pinned_ids = TaPinnedGrouping.pinned_custom_field_ids
        return [] if pinned_ids.empty?

        by_cf_id = all(user).each_with_object({}) do |field, acc|
          acc[field.custom_field.id] = field if field.custom_field
        end
        pinned_ids.filter_map { |id| by_cf_id[id] }
      end

      # Cheap guard so the controllers can tell "this view_mode might be a dimension" from
      # "this view_mode belongs to a pinned tab" without building the whole registry.
      def dimension?(key)
        key = key.to_s
        key.present? && !RESERVED_KEYS.include?(key)
      end

      # Payload for the picker endpoint, grouped into the three sections.
      def picker_payload(user = User.current)
        sections = [
          [SECTION_ISSUE_ATTRIBUTE, :label_groupable_issue_fields],
          [SECTION_TIME_ENTRY_CF,   :label_groupable_time_entry_custom_fields],
          [SECTION_ISSUE_CF,        :label_groupable_issue_custom_fields]
        ]
        fields = all(user)

        sections.filter_map do |section, label_key|
          entries = fields.select { |field| field.section == section }
          next if entries.empty?

          {
            section: section.to_s,
            label: ::I18n.t(label_key),
            fields: entries.map { |field| { key: field.key, label: field.label, pinned: field.pinned? } }
          }
        end
      end

      private

      def static_fields
        STATIC_FIELDS.map do |spec|
          model = spec[:model].constantize
          Field.new(
            key: spec[:key],
            label: ::I18n.t(spec[:label]),
            section: SECTION_ISSUE_ATTRIBUTE,
            group_sql: Arel.sql(spec[:column]),
            needs_issue_join: true,
            join_sql: nil,
            custom_field: nil,
            resolver: static_resolver(model)
          )
        end
      end

      # One batched lookup per pivot, never per row. Users are labelled by #name (which honours
      # Setting.user_format); everything else by its `name` column.
      def static_resolver(model)
        lambda do |raw_values|
          ids = raw_values.compact.map(&:to_i).uniq
          return {} if ids.empty?

          if model == User
            model.where(id: ids).to_h { |record| [record.id, record.name] }
          else
            model.where(id: ids).pluck(:id, :name).to_h
          end
        end
      end

      def custom_fields(user)
        eligible(TimeEntryCustomField, user).filter_map do |cf|
          build_custom_field(cf, 'cf_te', section: SECTION_TIME_ENTRY_CF, needs_issue_join: false)
        end +
          eligible(IssueCustomField, user).filter_map do |cf|
            build_custom_field(cf, 'cf_issue', section: SECTION_ISSUE_CF, needs_issue_join: true)
          end
      end

      # Eligibility reuses Redmine's own "Used as a filter" checkbox rather than introducing a
      # plugin-specific admin flag, on top of role-based visibility.
      def eligible(klass, user)
        klass.visible(user).where(is_filter: true).sorted.to_a.select do |cf|
          !cf.multiple? && GROUPABLE_CF_FORMATS.include?(cf.field_format)
        end
      end

      def build_custom_field(cf, prefix, section:, needs_issue_join:)
        expression = group_expression_for(cf)
        return nil if expression.blank?

        Field.new(
          key: "#{prefix}_#{cf.id}",
          label: cf.name,
          section: section,
          group_sql: Arel.sql(expression),
          needs_issue_join: needs_issue_join,
          join_sql: cf.join_for_order_statement,
          custom_field: cf,
          resolver: custom_field_resolver(cf)
        )
      end

      # CustomField#group_statement covers list/date/user/version. It returns nil for `string`
      # (Redmine::FieldFormat::Base#group_statement is nil and StringFormat doesn't override it),
      # but #order_statement returns exactly the right expression for that format —
      # COALESCE(cf_<id>.value, ''). That fallback is what makes string fields groupable here
      # without patching core.
      def group_expression_for(cf)
        expression = cf.group_statement || cf.order_statement
        # RecordList#order_statement can return an Array of columns; only a single scalar
        # expression is usable as a GROUP BY here.
        return nil unless expression.is_a?(String)

        expression.to_s
      end

      def custom_field_resolver(cf)
        target = cf.value_class

        lambda do |raw_values|
          values = raw_values.reject(&:blank?).uniq

          if target
            ids = values.map(&:to_i).uniq
            records = target.where(id: ids).index_by(&:id)
            values.to_h do |raw|
              record = records[raw.to_i]
              [raw, record ? record_label(record) : raw.to_s]
            end
          else
            # list/string/date store their display value directly in custom_values.value.
            values.to_h { |raw| [raw, raw.to_s] }
          end
        end
      end

      def record_label(record)
        record.respond_to?(:name) ? record.name : record.to_s
      end
    end
  end
end
