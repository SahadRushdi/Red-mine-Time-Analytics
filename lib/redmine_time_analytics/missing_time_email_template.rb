# frozen_string_literal: true

require 'erb'

module RedmineTimeAnalytics
  class MissingTimeEmailTemplate
    class << self
      def subject_for(date_range, period_type = nil)
        "Missing Time Entries for #{period_phrase(date_range, period_type)}"
      end

      # Plain-text fallback body, with one row per member across all teams.
      def body_for(missing_by_team:, date_range:, from_name:, period_type: nil)
        lines = []
        lines << 'Hi Team,'
        lines << ''
        lines << "This is a gentle reminder to review your time entries for #{period_phrase(date_range, period_type)} and ensure they are up to date."
        lines << ''
        lines << 'Team Member | Time Log Missed Days'
        missing_members(missing_by_team).each do |user, dates|
          lines << "#{user_name(user)} | #{format_missing_dates(dates)}"
        end
        lines << ''
        lines << 'If your time entries are already up to date or you were on leave, you can ignore this message.'
        lines << ''
        lines << "Best regards,\n#{from_name.presence || 'Time Analytics System'}"
        lines << ''
        lines << '(This is an automated email. Please do not reply.)'
        lines.join("\n")
      end

      # HTML body: one table containing all members with missing time.
      def body_html_for(missing_by_team:, date_range:, from_name:, period_type: nil)
        table = members_table_html(missing_members(missing_by_team))

        <<~HTML
          <div style="font-family: Arial, Helvetica, sans-serif; color:#1f2937; font-size:14px; line-height:1.6;">
            <p>Hi Team,</p>
            <p>This is a gentle reminder to review your time entries for <strong>#{esc(period_phrase(date_range, period_type))}</strong> and ensure they are up to date.</p>
            #{table}
            <p style="margin-top:20px;">If your time entries are already up to date or you were on leave, you can ignore this message.</p>
            <p>Best regards,<br>#{esc(from_name.presence || 'Time Analytics System')}</p>
            <p style="color:#6b7280; font-size:12px; margin-top:16px;">(This is an automated email. Please do not reply.)</p>
          </div>
        HTML
      end

      private

      def missing_members(missing_by_team)
        by_user = Hash.new { |users, user| users[user] = [] }
        Array(missing_by_team).each do |_team, user_dates|
          Array(user_dates).each do |user, dates|
            by_user[user].concat(Array(dates))
          end
        end
        by_user.sort_by { |user, _dates| [user_name(user).downcase, user_name(user)] }
      end

      def members_table_html(user_dates)
        cell = 'border:1px solid #d1d5db; padding:8px 12px;'
        head = "text-align:left; #{cell} background:#f3f4f6; font-weight:bold;"

        rows = Array(user_dates).map do |user, dates|
          "<tr>" \
            "<td style=\"#{cell}\">#{esc(user_name(user))}</td>" \
            "<td style=\"#{cell}\">#{esc(format_missing_dates(dates))}</td>" \
          "</tr>"
        end.join

        <<~HTML
          <table style="border-collapse:collapse; width:100%; max-width:640px;">
            <thead>
              <tr>
                <th style="#{head}">Team Member</th>
                <th style="#{head}">Time Log Missed Days</th>
              </tr>
            </thead>
            <tbody>#{rows}</tbody>
          </table>
        HTML
      end

      # Period wording for the subject/intro:
      #   :monthly → "the Month of June 2026"
      #   :weekly  → "the Week of June 22–26, 2026"
      #   :daily   → "June 29, 2026"
      # When period_type is nil it is inferred from the range (single day → daily, else weekly).
      def period_phrase(date_range, period_type = nil)
        first = date_range.first
        last = date_range.last
        type = period_type || (first == last ? :daily : :weekly)

        case type
        when :monthly
          "the Month of #{first.strftime('%B %Y')}"
        when :weekly
          "the Week of #{week_label(first, last)}"
        else
          long_date(first)
        end
      end

      def week_label(first, last)
        if first.year == last.year && first.month == last.month
          "#{first.strftime('%B %-d')}–#{last.strftime('%-d, %Y')}"
        elsif first.year == last.year
          "#{first.strftime('%B %-d')} – #{last.strftime('%B %-d, %Y')}"
        else
          "#{long_date(first)} – #{long_date(last)}"
        end
      end

      def long_date(date)
        return '' if date.blank?

        date.strftime('%B %-d, %Y')
      rescue StandardError
        date.to_s
      end

      def user_name(user)
        user.respond_to?(:name) ? user.name.to_s : user.to_s
      end

      def esc(text)
        ERB::Util.html_escape(text.to_s)
      end

      def format_missing_dates(dates)
        sorted = Array(dates).map(&:to_date).uniq.sort
        sorted.group_by { |date| [date.year, date.month] }.map do |_month, month_dates|
          "#{month_dates.first.strftime('%b')} #{month_dates.map(&:day).join(', ')}"
        end.join(', ')
      end
    end
  end
end
