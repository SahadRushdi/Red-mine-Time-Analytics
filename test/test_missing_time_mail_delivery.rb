#!/usr/bin/env ruby
# frozen_string_literal: true

# Reproduce disabled and suppressed delivery failures using the real ActionMailer/Mail stack.
require 'active_support/all'
require 'active_support/testing/time_helpers'
require 'action_mailer'
require 'minitest/autorun'
require 'stringio'
require 'logger'
require 'nokogiri'

module Rails
  class << self
    attr_accessor :logger
  end
end

class Setting
  def self.mail_from
    'notifications@example.test'
  end
end

# Emulate the global Redmine production setting before loading the custom mailer.
ActionMailer::Base.raise_delivery_errors = false
require_relative '../lib/redmine_time_analytics/missing_time_email_template'
require_relative '../app/mailers/missing_time_mailer'
require_relative '../lib/redmine_time_analytics/missing_time_notification_service'

class MissingTimeMailDeliveryTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  class LookupService < RedmineTimeAnalytics::MissingTimeNotificationService
    def users_missing_time_for_range(range)
      { 'Diagnostics' => { 'Member' => [range.last] } }
    end
  end

  class FailingSMTP
    def initialize(*)
    end

    def deliver!(_message)
      raise Net::SMTPAuthenticationError, '535 SMTP credentials rejected'
    end
  end

  def setup
    ActionMailer::Base.raise_delivery_errors = false
    @log = StringIO.new
    Rails.logger = Logger.new(@log)
    ActionMailer::Base.logger = nil
    MissingTimeMailer.view_paths = [File.expand_path('../app/views', __dir__)]
    MissingTimeMailer.delivery_method = :test
    MissingTimeMailer.perform_deliveries = true
    ActionMailer::Base.deliveries.clear
    Time.zone = 'UTC'
    travel_to Time.utc(2026, 10, 9, 12)
    @service = LookupService.new(settings: {
      timezone: 'Asia/Kolkata', recipients: ['recipient@example.test'], from_name: 'Time Analytics'
    })
  end

  def teardown
    travel_back
  end

  def test_disabled_deliveries_are_errors_and_never_log_sent
    MissingTimeMailer.perform_deliveries = false
    result = @service.notify_missing_time!(period: :weekly)
    refute result.sent
    assert_match(/Email delivery is disabled/, result.errors.first)
    assert_empty ActionMailer::Base.deliveries
    refute_match(/sent reminder/, @log.string)
  end

  def test_successful_transport_marks_sent
    result = @service.notify_missing_time!(period: :daily)
    assert_empty result.errors
    assert result.sent
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_match(/sent reminder/, @log.string)
  end

  def test_email_combines_teams_into_unique_alphabetical_member_rows
    message = reminder_message({
      'Team A' => { 'Zoe' => [Date.new(2026, 9, 5)], 'alice' => [Date.new(2026, 9, 2)] },
      'Team B' => { 'alice' => [Date.new(2026, 9, 1), Date.new(2026, 9, 2)] }
    })
    html = Nokogiri::HTML.fragment(message.html_part.body.decoded)
    assert_equal 1, html.css('table').size
    assert_empty html.css('h3')
    assert_equal ['Team Member', 'Time Log Missed Days'], html.css('th').map(&:text)
    assert_equal [['alice', 'Sep 1, 2'], ['Zoe', 'Sep 5']],
                 html.css('tbody tr').map { |row| row.css('td').map(&:text) }
    text = message.text_part.body.decoded
    assert_includes text, "Team Member | Time Log Missed Days\nalice | Sep 1, 2\nZoe | Sep 5"
    [text, html.text].each do |body|
      refute_includes body, 'Team A'
      refute_includes body, 'Team B'
    end
  end

  def test_missing_dates_show_each_month_once_and_enumerate_days
    cases = [
      [[Date.new(2026, 9, 1)], 'Sep 1'],
      [[5, 1, 2, 1].map { |day| Date.new(2026, 9, day) }, 'Sep 1, 2, 5'],
      [[Date.new(2026, 10, 2), Date.new(2026, 9, 30), Date.new(2026, 10, 1), Date.new(2026, 9, 29)],
       'Sep 29, 30, Oct 1, 2'],
      [[Date.new(2027, 1, 2), Date.new(2026, 12, 31), Date.new(2027, 1, 1)], 'Dec 31, Jan 1, 2'],
      [[Date.new(2027, 9, 2), Date.new(2026, 9, 1)], 'Sep 1, Sep 2']
    ]
    cases.each do |dates, expected|
      message = reminder_message({ 'Team A' => { 'Member' => dates } })
      html = Nokogiri::HTML.fragment(message.html_part.body.decoded)
      assert_equal expected, html.at_css('tbody tr td:last-child').text
      assert_includes message.text_part.body.decoded, "Member | #{expected}\n"
    end
  end

  def test_revised_wording_and_footer_in_both_email_parts
    message = reminder_message({ 'Team A' => { 'Member' => [Date.new(2026, 10, 12)] } }, from_name: '')
    intro = 'This is a gentle reminder to review your time entries for the Week of October 12–14, 2026 and ensure they are up to date.'
    ignore = 'If your time entries are already up to date or you were on leave, you can ignore this message.'
    footer = '(This is an automated email. Please do not reply.)'
    expected_text = "Hi Team,\n\n#{intro}\n\nTeam Member | Time Log Missed Days\nMember | Oct 12\n\n#{ignore}\n\nBest regards,\nTime Analytics System\n\n#{footer}"
    assert_equal expected_text, message.text_part.body.decoded.strip
    html = Nokogiri::HTML.fragment(message.html_part.body.decoded)
    assert_equal ['Hi Team,', intro, ignore, 'Best regards,Time Analytics System', footer], html.css('p').map(&:text)
    assert_equal footer, html.css('p').last.text
    assert_equal 'Missing Time Entries for the Week of October 12–14, 2026', message.subject
  end

  def test_html_escapes_names_and_preserves_distinct_members_with_the_same_name
    member = Struct.new(:id, :name)
    name = '<b>Alex & Sam</b>'
    message = reminder_message({ 'Team A' => {
      member.new(1, name) => [Date.new(2026, 9, 1)],
      member.new(2, name) => [Date.new(2026, 9, 2)]
    } }, from_name: 'Time & <Analytics>')
    html = Nokogiri::HTML.fragment(message.html_part.body.decoded)
    assert_equal [name, name], html.css('tbody tr td:first-child').map(&:text)
    assert_empty html.css('tbody b, p analytics')
    assert_includes html.css('p').map(&:text), 'Best regards,Time & <Analytics>'
    assert_includes message.text_part.body.decoded, 'Time & <Analytics>'
  end

  def test_smtp_failure_is_reported_despite_global_production_error_suppression
    refute ActionMailer::Base.raise_delivery_errors
    MissingTimeMailer.add_delivery_method(:failing_smtp, FailingSMTP)
    MissingTimeMailer.delivery_method = :failing_smtp
    result = @service.notify_missing_time!(period: :weekly)
    refute result.sent
    assert_match(/SMTP authentication failed/, result.errors.first)
    refute ActionMailer::Base.raise_delivery_errors
    assert_empty ActionMailer::Base.deliveries
    refute_match(/sent reminder/, @log.string)
  end

  private

  def reminder_message(missing_by_team, from_name: 'Time Analytics')
    MissingTimeMailer.reminder(
      missing_by_team: missing_by_team,
      date_range: Date.new(2026, 10, 12)..Date.new(2026, 10, 14),
      recipients: ['recipient@example.test'], from_name: from_name, period_type: :weekly
    ).message
  end
end
