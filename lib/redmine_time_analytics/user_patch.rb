module RedmineTimeAnalytics
  module UserPatch
    def self.included(base)
      base.class_eval do
        # Get teams where the user is a team lead (active memberships only)
        def led_teams(date = Date.today)
          TaTeamMembership.where(user: self, role: 'lead')
                          .where('start_date <= ?', date)
                          .where('end_date IS NULL OR end_date >= ?', date)
                          .includes(:team)
                          .map(&:team)
                          .uniq
        end

        # Check if user is a team lead for any team
        def is_team_lead?(date = Date.today)
          led_teams(date).any?
        end

        # Check if user is a team lead for a specific team
        def is_team_lead_for?(team, date = Date.today)
          TaTeamMembership.where(user: self, team: team, role: 'lead')
                          .where('start_date <= ?', date)
                          .where('end_date IS NULL OR end_date >= ?', date)
                          .exists?
        end
      end
    end
  end
end

# Apply patch to User model
User.include(RedmineTimeAnalytics::UserPatch) unless User.included_modules.include?(RedmineTimeAnalytics::UserPatch)
