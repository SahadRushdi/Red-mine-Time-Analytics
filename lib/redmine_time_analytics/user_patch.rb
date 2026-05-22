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

        # Check if user has global team analytics access
        def super_user_for_team_analytics?
          TaTeamSetting.user_super?(id)
        end

        # Check if user can access Team Analytics dashboard
        def can_access_team_analytics?(date = Date.today)
          return true if super_user_for_team_analytics?
          return true if admin? && is_team_lead?(date)
          return false unless TaTeamSetting.my_team_enabled?

          is_team_lead?(date)
        end

        # Get teams user can open as team dashboards
        # Super users get all teams; team leads get led teams + all descendants
        def accessible_team_dashboard_teams(date = Date.today)
          return TaTeam.all if super_user_for_team_analytics?
          return TaTeam.none if admin? && !is_team_lead?(date) && !TaTeamSetting.my_team_enabled?

          return TaTeam.none unless TaTeamSetting.my_team_enabled?

          led = led_teams(date)
          return TaTeam.none if led.empty?

          team_ids = led.flat_map { |team| [team.id] + team.all_descendants.map(&:id) }.uniq
          TaTeam.where(id: team_ids)
        end

        # Get team roots for hierarchy tree view
        # Super users get org roots; team leads get only teams they lead
        def team_dashboard_root_teams(date = Date.today)
          return TaTeam.root_teams if super_user_for_team_analytics?
          return led_teams(date) if admin? && is_team_lead?(date)

          led_teams(date)
        end
      end
    end
  end
end

# Apply patch to User model
User.include(RedmineTimeAnalytics::UserPatch) unless User.included_modules.include?(RedmineTimeAnalytics::UserPatch)
