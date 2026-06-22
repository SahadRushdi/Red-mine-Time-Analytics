# frozen_string_literal: true

module RedmineTimeAnalytics
  # Adds a display accessor for the assignee's job title, used by the
  # "Assignee's Title" query column on the Issues list.
  module IssuePatch
    def assigned_to_title
      assigned_to&.ta_title_name
    end
  end
end
