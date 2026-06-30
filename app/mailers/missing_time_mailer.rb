# frozen_string_literal: true

class MissingTimeMailer < ActionMailer::Base
  default from: -> { Setting.mail_from }

  def reminder(missing_by_team:, date_range:, recipients:, from_name:, period_type: nil)
    @body_text = RedmineTimeAnalytics::MissingTimeEmailTemplate.body_for(
      missing_by_team: missing_by_team,
      date_range: date_range,
      from_name: from_name,
      period_type: period_type
    )
    @body_html = RedmineTimeAnalytics::MissingTimeEmailTemplate.body_html_for(
      missing_by_team: missing_by_team,
      date_range: date_range,
      from_name: from_name,
      period_type: period_type
    )

    subject_text = RedmineTimeAnalytics::MissingTimeEmailTemplate.subject_for(date_range, period_type)
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
