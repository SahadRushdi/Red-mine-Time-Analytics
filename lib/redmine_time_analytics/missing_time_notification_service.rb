# frozen_string_literal: true

module RedmineTimeAnalytics
  class MissingTimeNotificationService
    Result = Struct.new(:date_range, :missing_users, :sent, :errors, keyword_init: true)

    def initialize(settings: TaTeamSetting.missing_time_settings)
      @settings = settings
    end

    def notify_missing_time!(date_range: nil)
      result = Result.new(date_range: nil, missing_users: {}, sent: false, errors: [])

      Time.use_zone(@settings[:timezone]) do
        today = Time.zone.today
        range = date_range || resolve_date_range(today)
        result.date_range = range

        missing_by_team = users_missing_time_for_range(range)
        result.missing_users = missing_by_team

        if missing_by_team.empty?
          Rails.logger.info("[MissingTimeScheduler] no missing time entries for #{range}")
          return result
        end

        begin
          MissingTimeMailer.reminder(
            missing_by_team: missing_by_team,
            date_range: range,
            recipients: @settings[:recipients],
            from_name: @settings[:from_name]
          ).deliver_now

          team_count = missing_by_team.size
          user_count = missing_by_team.values.flat_map(&:keys).uniq.size
          Rails.logger.info(
            "[MissingTimeScheduler] sent reminder for #{range} to #{Array(@settings[:recipients]).join(', ')} " \
            "(#{user_count} users across #{team_count} teams)"
          )

          result.sent = true
        rescue Net::SMTPAuthenticationError => e
          Rails.logger.error("[MissingTimeScheduler] SMTP auth failed when sending reminder: #{e.message}")
          result.errors << "SMTP authentication failed: #{e.message}"
        rescue StandardError => e
          Rails.logger.error("[MissingTimeScheduler] failed to send reminder: #{e.class}: #{e.message}")
          result.errors << "Mail send failed: #{e.class}: #{e.message}"
        end
      end

      result
    rescue StandardError => e
      result ||= Result.new(date_range: nil, missing_users: {}, sent: false, errors: [])
      result.errors << e.message
      result
    end

    private

    def resolve_date_range(today)
      case today.wday
      when 1 # Monday → previous week Mon–Fri
        monday = today - 7
        monday..monday + 4
      when 5, 6 # Friday or Saturday → current week Mon–Fri
        monday = today - (today.wday - 1)
        monday..monday + 4
      else
        prev = previous_working_day(today)
        Rails.logger.warn(
          "[MissingTimeScheduler] triggered on #{today.strftime('%A')} (not Mon/Fri/Sat); " \
          "falling back to single-day check for #{prev}"
        )
        prev..prev
      end
    end

    def previous_working_day(reference_date)
      date = reference_date - 1.day
      30.times do
        return date if RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(date)

        date -= 1.day
      end
      raise "Unable to find previous working day from #{reference_date}"
    end

    # Returns { TaTeam => { User => [Date, ...] } } grouped by the team(s) each user is a direct
    # member of. A user belonging to several teams appears under each of them (Scenario 1).
    # Membership is direct (not hierarchical), so a user assigned only to a sub-team never shows
    # under its parent teams (Scenario 2).
    def users_missing_time_for_range(date_range)
      all_dates = date_range.to_a
      # Use working_day_checker to load holidays once for the range rather than one DB call per date.
      is_working_day = RedmineTimeAnalytics::WorkingDaysCalculator.working_day_checker(
        all_dates.min, all_dates.max
      )
      working_dates = all_dates.select { |d| is_working_day.call(d) }
      return {} if working_dates.empty?

      # Direct team-member windows overlapping the checked range. Only users configured under a
      # team (TaTeamMembership) are considered; membership is resolved per-date so a user is
      # checked only on the working days their membership was active (end_date NULL or >= date).
      # team_id is kept so missing dates can be grouped back under the user's direct team(s).
      membership_windows = TaTeamMembership.active_between(working_dates.min, working_dates.max)
                                           .pluck(:team_id, :user_id, :start_date, :end_date)
      return {} if membership_windows.empty?

      user_windows = membership_windows.map { |_team_id, uid, start_d, end_d| [uid, start_d, end_d] }
      member_dates_by_user = dates_by_user_from_windows(user_windows, working_dates)
      team_user_ids = member_dates_by_user.keys
      return {} if team_user_ids.empty?

      # One query for all exclusion windows; per-date membership resolved in memory.
      exclusion_windows = TaTeamSetting.exclusions_overlapping(working_dates.min, working_dates.max)
                                        .pluck(:user_id, :start_date, :end_date)
      excluded_dates_by_user = dates_by_user_from_windows(exclusion_windows, working_dates)

      leave_dates_by_user = TaLeaveRecord.confirmed
                                         .where(leave_date: working_dates, user_id: team_user_ids)
                                         .pluck(:user_id, :leave_date)
                                         .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(uid, d), h|
                                           h[uid] << d.to_date
                                         end

      logged_dates_by_user = TimeEntry.joins(:project)
                                      .where(user_id: team_user_ids, spent_on: working_dates)
                                      .where(projects: { status: Project::STATUS_ACTIVE })
                                      .group(:user_id, :spent_on)
                                      .having('SUM(time_entries.hours) > 0')
                                      .pluck(:user_id, :spent_on)
                                      .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(uid, d), h|
                                        h[uid] << d.to_date
                                      end

      missing_by_user = {}
      team_user_ids.each do |uid|
        member_days   = member_dates_by_user[uid]
        excluded_days = excluded_dates_by_user[uid]
        leave_days    = leave_dates_by_user[uid]
        logged_days   = logged_dates_by_user[uid]
        checkable_dates = member_days - excluded_days - leave_days
        missing = checkable_dates - logged_days
        missing_by_user[uid] = missing unless missing.empty?
      end

      return {} if missing_by_user.empty?

      group_missing_by_team(membership_windows, missing_by_user)
    end

    # Distributes each user's missing dates back to the direct team(s) whose membership window
    # covers each date, returning an ordered { TaTeam => { User => [Date, ...] } }.
    def group_missing_by_team(membership_windows, missing_by_user)
      by_team = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
      membership_windows.each do |team_id, uid, start_d, end_d|
        dates = missing_by_user[uid]
        next if dates.blank?

        dates.each do |d|
          next unless d >= start_d && (end_d.nil? || d <= end_d)

          arr = by_team[team_id][uid]
          arr << d unless arr.include?(d)
        end
      end
      return {} if by_team.empty?

      teams_by_id = TaTeam.where(id: by_team.keys).index_by(&:id)
      user_ids = by_team.values.flat_map(&:keys).uniq
      users_by_id = User.where(id: user_ids).sorted.index_by(&:id)
      sorted_user_ids = users_by_id.keys

      ordered = {}
      by_team.keys.sort_by { |tid| teams_by_id[tid]&.name.to_s.downcase }.each do |tid|
        team = teams_by_id[tid]
        next if team.nil?

        user_map = by_team[tid]
        team_user_ordering = sorted_user_ids & user_map.keys
        rows = team_user_ordering.each_with_object({}) do |uid, h|
          user = users_by_id[uid]
          h[user] = user_map[uid].sort if user
        end
        ordered[team] = rows unless rows.empty?
      end
      ordered
    end

    # Builds { user_id => [Date, ...] }: for each working date, the users whose [start, end]
    # window covers it (end nil = open-ended). Used for both exclusion windows and membership
    # windows, via in-memory range checks on already-fetched windows. A user with several
    # windows (e.g. membership in multiple teams) still gets each date at most once.
    def dates_by_user_from_windows(windows, working_dates)
      by_user = Hash.new { |h, k| h[k] = [] }
      working_dates.each do |d|
        windows.each do |uid, start_d, end_d|
          next unless d >= start_d && (end_d.nil? || d <= end_d)

          by_user[uid] << d unless by_user[uid].include?(d)
        end
      end
      by_user
    end
  end
end
