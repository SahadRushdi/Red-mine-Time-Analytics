# frozen_string_literal: true

module RedmineTimeAnalytics
  # Adds a display accessor for the logging user's job title, used by the
  # "User's Title" query column on the Spent time view.
  module TimeEntryPatch
    def user_title
      user&.ta_title_name
    end
  end
end
