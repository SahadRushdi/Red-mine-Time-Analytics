# frozen_string_literal: true

module RedmineTimeAnalytics
  class MissingTimeEmailTemplate
    class << self
      def subject_for(target_date)
        "Missing time entries for #{formatted_date(target_date)}"
      end

      def body_for(missing_users:, target_date:, mail_date:, from_name:)
        lines = []
        lines << 'Hi Team,'
        lines << ''
        lines << "This is a gentle reminder to review your time entries for the day #{formatted_date(target_date)} and ensure they are up to date."
        lines << 'If your name is listed below, please take a moment to check your logged time and update any missing entries if needed.'
        lines << ''
        lines << 'Employees to review their time logs:'
        lines.concat(format_user_lines(missing_users))
        lines << ''
        lines << "Kindly complete any updates by end of day on #{formatted_date(mail_date)} to help maintain accurate reporting."
        lines << 'If your time entries are already up to date or you were on leave, you can ignore this message.'
        lines << ''
        lines << 'Thanks for your support in keeping our records accurate.'
        lines << "Best regards,\n#{from_name.presence || 'Time Analytics System'}"
        lines << ''
        lines << '(This is an automated email. Please do not reply.)'
        lines.join("\n")
      end

      private

      def formatted_date(date)
        return '' if date.blank?

        I18n.l(date)
      rescue StandardError
        date.to_s
      end

      def format_user_lines(users)
        Array(users).map do |user|
          name = user.respond_to?(:name) ? user.name.to_s : user.to_s
          email = user.respond_to?(:mail) && user.mail.present? ? user.mail : 'Email unavailable'
          "- #{name} (#{email})"
        end
      end
    end
  end
end
