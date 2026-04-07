# frozen_string_literal: true

class WeeklyTimeLogReminderMailer < Mailer
  helper :application

  def notify_low_time_logs(week_start:, week_end:, users:, threshold_hours:, working_days:, send_date: Date.today)
    @week_start = week_start
    @week_end = week_end
    @users = users
    @threshold_hours = threshold_hours
    @working_days = working_days
    @due_date = send_date

    recipient_emails = users.map { |u| u[:mail] }.uniq
    return if recipient_emails.empty?

    subject = "Time log reminder: #{date_range_label(@week_start, @week_end)}"

    mail(
      to: recipient_emails,
      subject: subject
    )
  end

  private

  def date_range_label(start_date, end_date)
    "#{I18n.l(start_date)} - #{I18n.l(end_date)}"
  end
end
