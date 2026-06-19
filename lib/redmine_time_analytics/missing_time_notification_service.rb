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

        user_missing_dates = users_missing_time_for_range(range)
        result.missing_users = user_missing_dates

        if user_missing_dates.empty?
          Rails.logger.info("[MissingTimeScheduler] no missing time entries for #{range}")
          return result
        end

        begin
          MissingTimeMailer.reminder(
            user_missing_dates: user_missing_dates,
            date_range: range,
            recipients: @settings[:recipients],
            from_name: @settings[:from_name]
          ).deliver_now

          Rails.logger.info(
            "[MissingTimeScheduler] sent reminder for #{range} to #{Array(@settings[:recipients]).join(', ')} " \
            "(#{user_missing_dates.length} users)"
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

    # Returns { user => [Date, ...] } for each user with at least one missing working day.
    def users_missing_time_for_range(date_range)
      active_user_ids = User.active.pluck(:id)
      return {} if active_user_ids.empty?

      all_dates = date_range.to_a
      # Use working_day_checker to load holidays once for the range rather than one DB call per date.
      is_working_day = RedmineTimeAnalytics::WorkingDaysCalculator.working_day_checker(
        all_dates.min, all_dates.max
      )
      working_dates = all_dates.select { |d| is_working_day.call(d) }
      return {} if working_dates.empty?

      # One query for all exclusion windows; per-date membership resolved in memory.
      exclusion_windows = TaTeamSetting.exclusions_overlapping(working_dates.min, working_dates.max)
                                        .pluck(:user_id, :start_date, :end_date)
      excluded_dates_by_user = build_excluded_dates_by_user(exclusion_windows, working_dates)

      leave_dates_by_user = TaLeaveRecord.confirmed
                                         .where(leave_date: working_dates, user_id: active_user_ids)
                                         .pluck(:user_id, :leave_date)
                                         .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(uid, d), h|
                                           h[uid] << d.to_date
                                         end

      logged_dates_by_user = TimeEntry.joins(:project)
                                      .where(user_id: active_user_ids, spent_on: working_dates)
                                      .where(projects: { status: Project::STATUS_ACTIVE })
                                      .group(:user_id, :spent_on)
                                      .having('SUM(time_entries.hours) > 0')
                                      .pluck(:user_id, :spent_on)
                                      .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(uid, d), h|
                                        h[uid] << d.to_date
                                      end

      result = {}
      active_user_ids.each do |uid|
        excluded_days = excluded_dates_by_user[uid]
        leave_days    = leave_dates_by_user[uid]
        logged_days   = logged_dates_by_user[uid]
        checkable_dates = working_dates - excluded_days - leave_days
        missing = checkable_dates - logged_days
        result[uid] = missing unless missing.empty?
      end

      return {} if result.empty?

      users_by_id = User.where(id: result.keys).sorted.index_by(&:id)
      result.transform_keys { |uid| users_by_id[uid] }.reject { |u, _| u.nil? }
    end

    # Builds { user_id => [Date, ...] } of dates each user is on the exclusion list,
    # using in-memory range checks on already-fetched exclusion windows.
    def build_excluded_dates_by_user(exclusion_windows, working_dates)
      excluded = Hash.new { |h, k| h[k] = [] }
      working_dates.each do |d|
        exclusion_windows.each do |uid, start_d, end_d|
          excluded[uid] << d if d >= start_d && (end_d.nil? || d <= end_d)
        end
      end
      excluded
    end
  end
end
