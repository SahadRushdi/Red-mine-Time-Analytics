# frozen_string_literal: true

class MissingTimeMailer < ActionMailer::Base
  default from: -> { Setting.mail_from }

  def reminder(user_missing_dates:, date_range:, recipients:, from_name:)
    @body_text = RedmineTimeAnalytics::MissingTimeEmailTemplate.body_for(
      user_missing_dates: user_missing_dates,
      date_range: date_range,
      from_name: from_name
    )

    subject_text = RedmineTimeAnalytics::MissingTimeEmailTemplate.subject_for(date_range)
    mail_options = { to: recipients, subject: subject_text }
    from_address = formatted_from(from_name)
    mail_options[:from] = from_address if from_address.present?
    mail(mail_options)
  end

  private

  def formatted_from(from_name)
    return nil if Setting.mail_from.blank?
    return Setting.mail_from if from_name.blank?

    "#{from_name} <#{Setting.mail_from}>"
  end
end
