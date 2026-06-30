# frozen_string_literal: true

require 'erb'

module RedmineTimeAnalytics
  class MissingTimeEmailTemplate
    class << self
      def subject_for(date_range)
        "Missing Time Entries for #{period_phrase(date_range)}"
      end

      # Plain-text fallback body. Lists each team and its un-logged members.
      def body_for(missing_by_team:, date_range:, from_name:)
        lines = []
        lines << 'Hi Team,'
        lines << ''
        lines << "This is a gentle reminder to review your time entries for #{period_phrase(date_range)} and ensure they are up to date."
        lines << 'If your name is listed below, please take a moment to check your logged time and update any missing entries if needed.'
        lines << ''

        Array(missing_by_team).each do |team, user_dates|
          lines << "#{team_name(team)}"
          Array(user_dates).each do |user, dates|
            lines << "  #{user_name(user)} -> #{format_missing_dates(dates)}"
          end
          lines << ''
        end

        lines << 'If your time entries are already up to date or you were on leave, you can ignore this message. Kindly complete any pending times.'
        lines << 'Thanks for your support in keeping our records accurate.'
        lines << "Best regards,\n#{from_name.presence || 'Time Analytics System'}"
        lines << ''
        lines << '(This is an automated email. Please do not reply.)'
        lines.join("\n")
      end

      # HTML body: one table per team with the team's un-logged members.
      def body_html_for(missing_by_team:, date_range:, from_name:)
        tables = Array(missing_by_team).map { |team, user_dates| team_table_html(team, user_dates) }.join

        <<~HTML
          <div style="font-family: Arial, Helvetica, sans-serif; color:#1f2937; font-size:14px; line-height:1.6;">
            <p>Hi Team,</p>
            <p>This is a gentle reminder to review your time entries for <strong>#{esc(period_phrase(date_range))}</strong> and ensure they are up to date. If your name is listed below, please take a moment to check your logged time and update any missing entries.</p>
            #{tables}
            <p style="margin-top:20px;">If your time entries are already up to date or you were on leave, you can ignore this message. Kindly complete any pending entries.</p>
            <p>Thanks for your support in keeping our records accurate.</p>
            <p>Best regards,<br>#{esc(from_name.presence || 'Time Analytics System')}</p>
            <p style="color:#6b7280; font-size:12px; margin-top:16px;">(This is an automated email. Please do not reply.)</p>
          </div>
        HTML
      end

      private

      def team_table_html(team, user_dates)
        cell = 'border:1px solid #d1d5db; padding:8px 12px;'
        head = "text-align:left; #{cell} background:#f3f4f6; font-weight:bold;"

        rows = Array(user_dates).map do |user, dates|
          "<tr>" \
            "<td style=\"#{cell}\">#{esc(user_name(user))}</td>" \
            "<td style=\"#{cell}\">#{esc(format_missing_dates(dates))}</td>" \
          "</tr>"
        end.join

        <<~HTML
          <h3 style="margin:20px 0 8px; font-size:16px; color:#111827;">#{esc(team_name(team))}</h3>
          <table style="border-collapse:collapse; width:100%; max-width:640px;">
            <thead>
              <tr>
                <th style="#{head}">Team Member</th>
                <th style="#{head}">Days Missing Time Log</th>
              </tr>
            </thead>
            <tbody>#{rows}</tbody>
          </table>
        HTML
      end

      # "the Week of June 22–26, 2026" for a multi-day range, or "June 29, 2026" for a single day.
      def period_phrase(date_range)
        first = date_range.first
        last = date_range.last
        return long_date(first) if first == last

        "the Week of #{week_label(first, last)}"
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

      def team_name(team)
        team.respond_to?(:name) ? team.name.to_s : team.to_s
      end

      def user_name(user)
        user.respond_to?(:name) ? user.name.to_s : user.to_s
      end

      def esc(text)
        ERB::Util.html_escape(text.to_s)
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
