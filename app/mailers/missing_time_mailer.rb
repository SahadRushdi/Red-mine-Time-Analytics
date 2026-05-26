# frozen_string_literal: true

class MissingTimeMailer < Mailer
  def reminder(missing_users:, target_date:, mail_date:, recipients:, from_name:)
    @body_text = RedmineTimeAnalytics::MissingTimeEmailTemplate.body_for(
      missing_users: missing_users,
      target_date: target_date,
      mail_date: mail_date,
      from_name: from_name
    )

    subject_text = RedmineTimeAnalytics::MissingTimeEmailTemplate.subject_for(target_date)
    mail(to: recipients, subject: subject_text, from: formatted_from(from_name))
  end

  private

  def formatted_from(from_name)
    return Setting.mail_from if from_name.blank? || Setting.mail_from.blank?

    "#{from_name} <#{Setting.mail_from}>"
  end
end
