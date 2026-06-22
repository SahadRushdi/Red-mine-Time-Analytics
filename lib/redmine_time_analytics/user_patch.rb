module RedmineTimeAnalytics
  module UserPatch
    def self.included(base)
      base.class_eval do
        after_save :handle_ta_user_lock

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

        # --- User Title (job title) helpers ---

        # The TaUserTitle record for this user (nil if none assigned)
        def ta_user_title
          return @ta_user_title if defined?(@ta_user_title)

          @ta_user_title = TaUserTitle.find_by(user_id: id)
        end

        # The TaHiringTitle assigned to this user, or nil
        def ta_title
          ta_user_title&.title
        end

        # The assigned title text, or nil. Used by query/report column display.
        def ta_title_name
          ta_title&.title
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

        private

        def handle_ta_user_lock
          return unless status == User::STATUS_LOCKED

          # 1. Update active team memberships (end_date is nil or in the future)
          memberships = TaTeamMembership.where(user_id: id)
                                       .where('end_date IS NULL OR end_date > ?', Date.today)
          
          memberships.update_all(end_date: Date.today) if memberships.any?

          # 2. Delete super user and exclusion list settings
          settings = TaTeamSetting.where(user_id: id, setting_type: ['super_user', 'exclusion'])
          settings.destroy_all if settings.any?

          # 3. Remove the user's title assignment so locked users drop out of title grouping
          TaUserTitle.where(user_id: id).destroy_all
        end
      end
    end
  end
end

# Apply patch to User model
User.include(RedmineTimeAnalytics::UserPatch) unless User.included_modules.include?(RedmineTimeAnalytics::UserPatch)
