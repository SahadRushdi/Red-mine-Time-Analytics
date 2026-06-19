# frozen_string_literal: true

module RedmineTimeAnalytics
  class MissingTimeEmailTemplate
    class << self
      def subject_for(date_range)
        "Missing time entries for the period #{formatted_date(date_range.first)} – #{formatted_date(date_range.last)}"
      end

      def body_for(user_missing_dates:, date_range:, from_name:)
        period = "#{formatted_date(date_range.first)} – #{formatted_date(date_range.last)}"
        lines = []
        lines << 'Hi Team,'
        lines << ''
        lines << "This is a gentle reminder to review your time entries for the period #{period} and ensure they are up to date."
        lines << 'If your name is listed below, please take a moment to check your logged time and update any missing entries if needed.'
        lines << ''
        lines << 'Employees to review their time logs:'
        lines.concat(format_user_lines(user_missing_dates))
        lines << ''
        lines << 'If your time entries are already up to date or you were on leave, you can ignore this message. Kindly complete any pending times.'
        lines << 'Thanks for your support in keeping our records accurate.'
        lines << "Best regards,\n#{from_name.presence || 'Time Analytics System'}"
        lines << ''
        lines << '(This is an automated email. Please do not reply.)'
        lines.join("\n")
      end

      private

      def formatted_date(date)
        return '' if date.blank?

        date.strftime('%b %d, %Y')
      rescue StandardError
        date.to_s
      end

      def format_user_lines(user_missing_dates)
        Array(user_missing_dates).map do |user, dates|
          name = user.respond_to?(:name) ? user.name.to_s : user.to_s
          "#{name} -> #{format_missing_dates(dates)}"
        end
      end

      def format_missing_dates(dates)
        sorted = Array(dates).map(&:to_date).sort
        return '' if sorted.empty?

        groups = sorted.each_with_object([]) do |d, acc|
          if acc.last&.last == d - 1
            acc.last << d
          else
            acc << [d]
          end
        end

        groups.map do |g|
          if g.length == 1
            g.first.strftime('%b %d')
          else
            "#{g.first.strftime('%b %d')} to #{g.last.strftime('%b %d')}"
          end
        end.join(', ')
      end
    end
  end
end
