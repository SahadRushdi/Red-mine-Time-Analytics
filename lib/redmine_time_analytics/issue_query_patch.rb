# frozen_string_literal: true

module RedmineTimeAnalytics
  # Adds an "Assignee's Title" column, filter and group-by to the Issues list.
  #
  # The title is joined off issues.assigned_to_id via ta_user_titles -> ta_hiring_titles.
  # ta_user_titles has a unique user_id, so the LEFT JOIN yields at most one row per
  # issue and does not inflate aggregates.
  module IssueQueryPatch
    # Aliased (iut/iht) to avoid clashing with any other title joins.
    def base_scope
      super.joins(
        "LEFT JOIN #{TaUserTitle.table_name} iut ON iut.user_id = #{Issue.table_name}.assigned_to_id " \
        "LEFT JOIN #{TaHiringTitle.table_name} iht ON iht.id = iut.title_id"
      )
    end

    def available_columns
      columns = super
      unless columns.any? { |c| c.name == :assigned_to_title }
        column = QueryColumn.new(
          :assigned_to_title,
          caption: :field_assigned_to_title,
          sortable: 'iht.title',
          groupable: true
        )
        # Override the GROUP BY SQL to the joined title alias (see #base_scope).
        column.define_singleton_method(:group_by_statement) { 'iht.title' }
        columns << column
      end
      columns
    end

    def initialize_available_filters
      super
      add_available_filter(
        'assigned_to_title_id',
        type: :list,
        name: l(:field_assigned_to_title),
        values: -> { TaHiringTitle.active_ordered.map { |t| [t.title, t.id.to_s] } }
      )
    end

    def sql_for_assigned_to_title_id_field(_field, operator, value)
      title_ids = Array(value).reject(&:blank?).map(&:to_i)
      subquery = "SELECT #{TaUserTitle.table_name}.user_id FROM #{TaUserTitle.table_name} " \
                 "WHERE #{TaUserTitle.table_name}.title_id IN (#{title_ids.join(',')})"

      case operator
      when '='
        title_ids.empty? ? '1=0' : "#{Issue.table_name}.assigned_to_id IN (#{subquery})"
      when '!'
        title_ids.empty? ? '1=1' : "#{Issue.table_name}.assigned_to_id NOT IN (#{subquery})"
      else
        '1=1'
      end
    end
  end
end
