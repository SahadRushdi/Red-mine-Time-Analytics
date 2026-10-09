#!/usr/bin/env ruby
# frozen_string_literal: true

# Reproduce disabled and suppressed delivery failures using the real ActionMailer/Mail stack.
require 'active_support/all'
require 'active_support/testing/time_helpers'
require 'action_mailer'
require 'minitest/autorun'
require 'stringio'
require 'logger'

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
end
