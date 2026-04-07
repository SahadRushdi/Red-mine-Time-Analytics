# frozen_string_literal: true

require 'date'

module RedmineTimeAnalytics
  class WeeklyTimeLogReminder
    TEST_RECIPIENT_ALLOWLIST = [
      'sahad@entgra.io',
      'turboturtle2244@gmail.com',
      'rushdi1823@gmail.com'
    ].freeze

    class << self
      def run!(today: Date.today, send_email: true, force_run: false)
        # Production logic (uncomment when promoting):
        # return { skipped: true, reason: 'weekday_not_allowed' } unless eligible_run_day?(today)

        # Testing logic (active): allow forcing execution outside Mon/Tue.
        return { skipped: true, reason: 'weekday_not_allowed' } unless force_run || eligible_run_day?(today)

        week_start, week_end = previous_week_work_window(today)
        working_days = WorkingDaysCalculator.working_days_count(week_start, week_end)
        threshold_hours = 20.0
        user_hours = fetch_user_hours(week_start, week_end)
        users_to_notify = build_users_to_notify(user_hours, threshold_hours)
        users_to_deliver = filter_users_for_delivery(users_to_notify)
        log_run_context(week_start, week_end, threshold_hours, user_hours, users_to_notify, users_to_deliver)

        if send_email && users_to_deliver.any?
          WeeklyTimeLogReminderMailer.notify_low_time_logs(
            week_start: week_start,
            week_end: week_end,
            users: users_to_deliver,
            threshold_hours: threshold_hours,
            working_days: working_days,
            send_date: today
          ).deliver_now
        end

        {
          skipped: false,
          week_start: week_start,
          week_end: week_end,
          working_days: working_days,
          threshold_hours: threshold_hours,
          users_checked: user_hours.size,
          users_notified: users_to_deliver.size,
          notified_users: users_to_deliver.map { |u| "#{u[:firstname]} #{u[:lastname]}".strip }
        }
      end

      private

      def eligible_run_day?(date)
        date.monday? || date.tuesday?
      end

      def previous_week_work_window(date)
        previous_week_start = date.beginning_of_week - 7
        [previous_week_start, previous_week_start + 4]
      end

      def fetch_user_hours(week_start, week_end)
        active_status = if User.const_defined?(:STATUS_ACTIVE)
                          User::STATUS_ACTIVE
                        else
                          1
                        end

        hours_by_user = TimeEntry.joins(:project)
                                 .where(spent_on: week_start..week_end)
                                 .where(projects: { status: Project::STATUS_ACTIVE })
                                 .group(:user_id)
                                 .sum(:hours)

        users = User.joins(:email_address)
                    .where(status: active_status)
                    .where.not(email_addresses: { address: [nil, ''] })
                    .order(:firstname, :lastname)
                    .to_a

        users.map do |user|
          email = resolve_user_email(user)
          next if email.empty?

          {
            id: user.id,
            firstname: user.firstname.to_s,
            lastname: user.lastname.to_s,
            mail: email,
            hours: hours_by_user[user.id].to_f
          }
        end.compact
      end

      def build_users_to_notify(user_hours, threshold_hours)
        user_hours.select { |entry| entry[:hours] <= threshold_hours }
      end

      def filter_users_for_delivery(users_to_notify)
        # Production logic (uncomment when promoting):
        # users_to_notify

        # Testing logic (active): only deliver to selected addresses.
        allowed = TEST_RECIPIENT_ALLOWLIST.map { |mail| normalize_email(mail) }
        users_to_notify.select do |entry|
          allowed.include?(normalize_email(entry[:mail]))
        end
      end

      def normalize_email(email)
        email.to_s.strip.downcase
      end

      def resolve_user_email(user)
        if user.respond_to?(:mail)
          mail = user.mail.to_s.strip
          return mail unless mail.empty?
        end

        if user.respond_to?(:email_address)
          address = user.email_address&.address.to_s.strip
          return address unless address.empty?
        end

        ''
      end

      def log_run_context(week_start, week_end, threshold_hours, user_hours, users_to_notify, users_to_deliver)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        Rails.logger.info(
          "[redmine_time_analytics] Weekly reminder selection: " \
          "week=#{week_start}..#{week_end}, threshold=#{threshold_hours}, " \
          "users_checked=#{user_hours.size}, users_to_notify=#{users_to_notify.size}, users_to_deliver=#{users_to_deliver.size}, " \
          "deliver_to=#{users_to_deliver.map { |u| normalize_email(u[:mail]) }.join(',')}"
        )
      end
    end
  end
end
