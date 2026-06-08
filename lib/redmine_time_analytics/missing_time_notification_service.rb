# frozen_string_literal: true

module RedmineTimeAnalytics
  class MissingTimeNotificationService
    Result = Struct.new(:target_date, :mail_date, :missing_users, :sent, :errors, keyword_init: true)

    def initialize(settings: TaTeamSetting.missing_time_settings)
      @settings = settings
    end

    def notify_missing_time!
      result = Result.new(
        target_date: nil,
        mail_date: nil,
        missing_users: [],
        sent: false,
        errors: []
      )

      Time.use_zone(@settings[:timezone]) do
        today = Time.zone.today
        target_date = previous_working_day(today)
        result.target_date = target_date
        result.mail_date = today

        missing_users = users_missing_time(target_date)
        result.missing_users = missing_users
        if missing_users.empty?
          Rails.logger.info("[MissingTimeScheduler] no missing time entries for #{target_date}")
          return result
        end

        begin
          MissingTimeMailer.reminder(
            missing_users: missing_users,
            target_date: target_date,
            mail_date: today,
            recipients: @settings[:recipients],
            from_name: @settings[:from_name]
          ).deliver_now

          Rails.logger.info(
            "[MissingTimeScheduler] sent reminder for #{target_date} to #{Array(@settings[:recipients]).join(', ')} "\
            "(#{missing_users.length} users)"
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
      result ||= Result.new(target_date: nil, mail_date: nil, missing_users: [], sent: false, errors: [])
      result.errors << e.message
      result
    end

    private

    def previous_working_day(reference_date)
      date = reference_date - 1.day
      30.times do
        return date if RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(date)

        date -= 1.day
      end
      raise "Unable to find previous working day from #{reference_date}"
    end

    def users_missing_time(date)
      active_users = User.active
      active_user_ids = active_users.pluck(:id)
      return [] if active_user_ids.empty?

      excluded_ids = TaTeamSetting.excluded_user_ids_for_date(date)
      leave_ids = TaLeaveRecord.confirmed.where(leave_date: date).pluck(:user_id)
      candidate_ids = active_user_ids - excluded_ids - leave_ids
      return [] if candidate_ids.empty?

      logged_user_ids = TimeEntry.joins(:project)
                                  .where(user_id: candidate_ids, spent_on: date)
                                  .where(projects: { status: Project::STATUS_ACTIVE })
                                  .includes(:project, :issue, :activity)
                                  .group(:user_id)
                                  .having('SUM(time_entries.hours) > 0')
                                  .pluck(:user_id)

      missing_ids = candidate_ids - logged_user_ids
      return [] if missing_ids.empty?

      User.where(id: missing_ids).sorted.to_a
    end
  end
end
