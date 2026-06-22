# frozen_string_literal: true

module RedmineTimeAnalytics
  # Adds "User's Title" as a grouping criterion to the Spent time Report tab,
  # giving total hours per title (pivoted by period).
  #
  # No :joins is supplied because the report scope is built from
  # TimeEntryQuery#results_scope -> base_scope, which already LEFT JOINs the
  # ta_hiring_titles table under the alias "tht" (see TimeEntryQueryPatch).
  module TimeReportPatch
    def load_available_criteria
      super
      @available_criteria['user_title'] = {
        sql: 'tht.title',
        label: :field_user_title
      }
      @available_criteria
    end
  end
end
