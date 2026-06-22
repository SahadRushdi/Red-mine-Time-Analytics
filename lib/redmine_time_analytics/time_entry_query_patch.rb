# frozen_string_literal: true

module RedmineTimeAnalytics
  # Adds a "User's Title" column, filter and group-by to the Spent time view.
  #
  # The title is joined off the logging user via ta_user_titles -> ta_hiring_titles.
  # Because ta_user_titles has a unique user_id, the LEFT JOIN yields at most one row
  # per time entry, so it does not inflate COUNT/SUM aggregates.
  module TimeEntryQueryPatch
    # Aliased (tut/tht) so the group/sort SQL can reference the title column unambiguously.
    def base_scope
      super.joins(
        "LEFT JOIN #{TaUserTitle.table_name} tut ON tut.user_id = #{TimeEntry.table_name}.user_id " \
        "LEFT JOIN #{TaHiringTitle.table_name} tht ON tht.id = tut.title_id"
      )
    end

    def available_columns
      columns = super
      unless columns.any? { |c| c.name == :user_title }
        column = QueryColumn.new(
          :user_title,
          caption: :field_user_title,
          sortable: 'tht.title',
          groupable: true
        )
        # QueryColumn#group_by_statement returns the column name by default; override
        # it to the joined title SQL (alias defined in #base_scope) so GROUP BY works.
        column.define_singleton_method(:group_by_statement) { 'tht.title' }
        columns << column
      end
      columns
    end

    def initialize_available_filters
      super
      add_available_filter(
        'user_title_id',
        type: :list,
        name: l(:field_user_title),
        values: -> { TaHiringTitle.active_ordered.map { |t| [t.title, t.id.to_s] } }
      )
    end

    def sql_for_user_title_id_field(_field, operator, value)
      title_ids = Array(value).reject(&:blank?).map(&:to_i)
      subquery = "SELECT #{TaUserTitle.table_name}.user_id FROM #{TaUserTitle.table_name} " \
                 "WHERE #{TaUserTitle.table_name}.title_id IN (#{title_ids.join(',')})"

      case operator
      when '='
        title_ids.empty? ? '1=0' : "#{TimeEntry.table_name}.user_id IN (#{subquery})"
      when '!'
        title_ids.empty? ? '1=1' : "#{TimeEntry.table_name}.user_id NOT IN (#{subquery})"
      else
        '1=1'
      end
    end
  end
end
