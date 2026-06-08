# frozen_string_literal: true

class MissingTimeMailer < ActionMailer::Base
  default from: -> { Setting.mail_from }

  def reminder(missing_users:, target_date:, mail_date:, recipients:, from_name:)
    @body_text = RedmineTimeAnalytics::MissingTimeEmailTemplate.body_for(
      missing_users: missing_users,
      target_date: target_date,
      mail_date: mail_date,
      from_name: from_name
    )

    subject_text = RedmineTimeAnalytics::MissingTimeEmailTemplate.subject_for(target_date)
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
