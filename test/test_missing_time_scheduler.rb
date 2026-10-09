#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone tests: actual setting normalization, cron parsing and service logic;
# database settings, time-entry lookup and email delivery are replaced in memory.
ENV['TZ'] = 'UTC'
ENV['MISSING_TIME_SCHEDULER_DISABLED'] = '1'

require 'active_record'
require 'active_support/all'
require 'active_support/testing/time_helpers'
require 'minitest/autorun'
require 'logger'
require 'net/smtp'
require 'action_view'
require 'rack'
require 'yaml'
require 'nokogiri'

class Setting
  class << self
    attr_accessor :plugin_redmine_time_analytics
  end
end

module Rails
  def self.logger
    @logger ||= Logger.new(File::NULL)
  end
end

require_relative '../app/models/ta_team_setting'
require_relative '../lib/redmine_time_analytics/missing_time_scheduler'
require_relative '../lib/redmine_time_analytics/missing_time_notification_service'
require_relative '../lib/redmine_time_analytics/missing_time_email_template'

class MissingTimeMailer
  class << self
    attr_accessor :deliveries, :fail_delivery, :perform_deliveries, :skip_delivery

    def reminder(**options)
      delivery = Object.new
      message = Struct.new(:perform_deliveries).new(perform_deliveries)
      delivery.define_singleton_method(:message) { message }
      delivery.define_singleton_method(:deliver_now) do
        return nil if MissingTimeMailer.skip_delivery
        raise 'SMTP unavailable' if MissingTimeMailer.fail_delivery

        MissingTimeMailer.deliveries << options
        message
      end
      delivery
    end
  end
end

class MissingTimeSchedulerTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  Scheduler = RedmineTimeAnalytics::MissingTimeScheduler
  Service = RedmineTimeAnalytics::MissingTimeNotificationService

  class LookupService < Service
    attr_accessor :missing
    attr_reader :queried_range

    def users_missing_time_for_range(range)
      @queried_range = range
      @missing || {}
    end
  end

  class FakeJob
    attr_reader :cron
    attr_accessor :unscheduled

    def initialize(cron, callback)
      @cron, @callback = cron, callback
    end

    def fire
      @callback.call
    end

    def unschedule
      @unscheduled = true
    end
  end

  class FakeScheduler
    attr_reader :jobs

    def initialize
      @jobs = []
    end

    def cron(expression, &callback)
      FakeJob.new(expression, callback).tap { |job| @jobs << job }
    end
  end

  def setup
    @old_settings = Setting.plugin_redmine_time_analytics
    @old_scheduler = Scheduler.instance_variable_get(:@scheduler)
    @old_jobs = Scheduler.instance_variable_get(:@jobs)
    Setting.plugin_redmine_time_analytics = {}
    MissingTimeMailer.deliveries = []
    MissingTimeMailer.fail_delivery = false
    MissingTimeMailer.perform_deliveries = true
    MissingTimeMailer.skip_delivery = false
    Time.zone = 'UTC'
  end

  def teardown
    travel_back
    Setting.plugin_redmine_time_analytics = @old_settings
    Scheduler.instance_variable_set(:@scheduler, @old_scheduler)
    Scheduler.instance_variable_set(:@jobs, @old_jobs)
  end

  def row(cron = '0 18 * * *', weekly: true, daily: false)
    { cron: cron, weekly: weekly, daily: daily }
  end

  def settings(schedules = [])
    { enabled: true, schedules: schedules, timezone: 'Asia/Kolkata',
      recipients: ['admin@example.com'], from_name: 'Time Analytics' }
  end

  def test_weekly_and_daily_ranges_for_every_weekday
    service = Service.new(settings: settings)
    monday = Date.new(2026, 10, 5)
    7.times do |offset|
      today = monday + offset
      expected = offset.zero? ? (monday - 7..monday - 1) : (monday..today)
      assert_equal [expected, :weekly], service.send(:resolve_date_range, today, :weekly)
      assert_equal [today..today, :daily], service.send(:resolve_date_range, today, :daily)
      assert_equal [expected, :weekly], service.send(:resolve_date_range, today)
    end
    # Monday's previous week can cross a year boundary.
    assert_equal [Date.new(2025, 12, 29)..Date.new(2026, 1, 4), :weekly],
                 service.send(:resolve_date_range, Date.new(2026, 1, 5), :weekly)
  end

  def test_monthly_cron_embeds_timezone_and_runs_on_first_at_18
    assert_equal '0 18 1 * * Asia/Kolkata', Scheduler.monthly_cron('Asia/Kolkata')
    assert_equal Scheduler.monthly_cron('Asia/Kolkata'), Scheduler.monthly_cron(nil)
    assert_equal Scheduler.monthly_cron('Asia/Kolkata'), Scheduler.monthly_cron('')
    cron = Scheduler.cron_line_for(Scheduler.monthly_cron('Asia/Kolkata'))
    assert_equal 'Asia/Kolkata', cron.zone
    assert_equal Time.utc(2026, 11, 1, 12, 30), cron.next_time(Time.utc(2026, 10, 9)).to_t.utc
    assert_equal Time.utc(2026, 12, 1, 12, 30), cron.next_time(Time.utc(2026, 11, 1, 12, 31)).to_t.utc
    utc_cron = Scheduler.cron_line_for(Scheduler.monthly_cron('UTC'))
    assert_equal Time.utc(2026, 11, 1, 18), utc_cron.next_time(Time.utc(2026, 10, 9)).to_t.utc
  end

  def test_monthly_ranges_include_complete_previous_month
    [[Date.new(2026, 11, 1), Date.new(2026, 10, 1), Date.new(2026, 10, 31)],
     [Date.new(2026, 1, 1), Date.new(2025, 12, 1), Date.new(2025, 12, 31)],
     [Date.new(2028, 3, 1), Date.new(2028, 2, 1), Date.new(2028, 2, 29)],
     [Date.new(2026, 3, 1), Date.new(2026, 2, 1), Date.new(2026, 2, 28)]].each do |today, first, last|
      travel_to Time.utc(today.year, today.month, today.day, 12)
      service = LookupService.new(settings: settings)
      result = service.notify_missing_time!(period: :monthly)
      assert_empty result.errors
      assert_equal first..last, result.date_range
      assert_equal first..last, service.queried_range
      refute result.sent
    end
  end

  def test_monthly_gate_uses_notification_timezone
    # UTC is still October 31, while the configured timezone is already November 1.
    travel_to Time.utc(2026, 10, 31, 20)
    service = LookupService.new(settings: settings)
    assert_equal Date.new(2026, 10, 1)..Date.new(2026, 10, 31), service.notify_missing_time!(period: :monthly).date_range
    travel_to Time.utc(2026, 11, 1, 20)
    service = LookupService.new(settings: settings)
    assert_nil service.notify_missing_time!(period: :monthly).date_range
    assert_nil service.queried_range
  end

  def test_daily_uses_today_in_configured_timezone_and_preserves_overrides
    travel_to Time.utc(2026, 10, 8, 20)
    service = LookupService.new(settings: settings)
    assert_equal Date.new(2026, 10, 9)..Date.new(2026, 10, 9), service.notify_missing_time!(period: :daily).date_range
    override = Date.new(2026, 9, 1)..Date.new(2026, 9, 3)
    assert_equal override, service.notify_missing_time!(date_range: override, period: :weekly).date_range
    travel_to Time.utc(2026, 11, 1, 12)
    assert_equal override, service.notify_missing_time!(date_range: override, period: :monthly).date_range
  end

  def test_legacy_settings_become_weekly_only
    Setting.plugin_redmine_time_analytics = { 'missing_time_crons' => [' 0 18 * * 5 ', '0 8 * * 1', ''] }
    assert_equal [row('0 18 * * 5'), row('0 8 * * 1')], TaTeamSetting.missing_time_settings[:schedules]
    Setting.plugin_redmine_time_analytics = { 'missing_time_cron' => '0 18 * * 5', 'missing_time_cron_sat' => '0 10 * * 6', 'missing_time_cron_mon' => '0 8 * * 1' }
    assert_equal [row('0 18 * * 5'), row('0 10 * * 6'), row('0 8 * * 1')], TaTeamSetting.missing_time_settings[:schedules]
  end

  def test_empty_new_list_never_restores_legacy_rows
    [[], {}, { '_empty' => { 'cron' => '' } }].each do |empty|
      Setting.plugin_redmine_time_analytics = { 'missing_time_schedules' => empty, 'missing_time_crons' => ['0 18 * * 5'], 'missing_time_cron_mon' => '0 8 * * 1' }
      assert_empty TaTeamSetting.missing_time_settings[:schedules]
    end
  end

  def test_settings_writer_round_trip_preserves_all_modes_and_other_settings
    rows = [row, row(weekly: false, daily: true), row(daily: true), row(weekly: false)]
    Setting.plugin_redmine_time_analytics = { 'leave_sync_enabled' => '1', 'leave_sync_cron' => '*/10 * * * *' }
    TaTeamSetting.update_missing_time_settings!(enabled: '1', recipients: 'admin@example.com', schedules: rows)
    assert_equal rows, TaTeamSetting.missing_time_settings[:schedules]
    assert_equal '1', Setting.plugin_redmine_time_analytics['leave_sync_enabled']
    assert_equal '*/10 * * * *', Setting.plugin_redmine_time_analytics['leave_sync_cron']
    TaTeamSetting.update_missing_time_settings!(enabled: '1', recipients: 'admin@example.com', crons: ['0 8 * * 1'])
    assert_equal [row('0 8 * * 1')], TaTeamSetting.missing_time_settings[:schedules]
    assert_raises(ArgumentError) do
      TaTeamSetting.update_missing_time_settings!(enabled: '1', recipients: 'admin@example.com', schedules: [row('invalid cron')])
    end
  end

  def test_indexed_form_payload_keeps_unchecked_values_and_ignores_blank_rows
    payload = Rack::Utils.parse_nested_query('settings[missing_time_schedules][_empty][cron]=&settings[missing_time_schedules][0][cron]=0+18+*+*+*&settings[missing_time_schedules][0][weekly]=0&settings[missing_time_schedules][0][weekly]=1&settings[missing_time_schedules][0][daily]=0&settings[missing_time_schedules][2][cron]=0+8+*+*+1&settings[missing_time_schedules][2][weekly]=0&settings[missing_time_schedules][2][daily]=0')
    assert_equal [row, row('0 8 * * 1', weekly: false)], TaTeamSetting.missing_time_schedules(payload['settings'])
  end

  def test_rendered_settings_form_round_trip_and_row_removal
    translations = YAML.load_file(File.expand_path('../config/locales/en.yml', __dir__))['en']
    view = ActionView::Base.with_empty_template_cache.new(ActionView::LookupContext.new([]), {}, nil)
    view.define_singleton_method(:l) { |key| translations[key.to_s] || key.to_s }
    rows = [row, row(weekly: false, daily: true), row(daily: true), row(weekly: false)]
    raw = { 'missing_time_schedules' => rows, 'leave_sync_enabled' => '1',
            'leave_sync_options' => { 'folder' => 'Inbox' }, 'other_list' => ['first', 'second'] }
    html = view.render(inline: File.read(File.expand_path('../app/views/settings/_redmine_time_analytics_settings.html.erb', __dir__)), locals: { settings: raw })
    document = Nokogiri::HTML.fragment(html)
    assert_equal 4, document.css('.missing-time-cron-row').size
    assert_equal 8, document.css('input[type="checkbox"][name*="missing_time_schedules"]').size
    # Serialize successful form controls like a browser, including hidden unchecked values.
    encode = lambda do
      controls = document.css('input').filter_map do |input|
        next if input['type'] == 'checkbox' && !input.key?('checked')

        [input['name'], input['value'] || '']
      end
      Rack::Utils.parse_nested_query(URI.encode_www_form(controls))['settings']
    end
    submitted = encode.call
    assert_equal rows, TaTeamSetting.missing_time_schedules(submitted)
    assert_equal '1', submitted['leave_sync_enabled']
    assert_equal({ 'folder' => 'Inbox' }, submitted['leave_sync_options'])
    assert_equal ['first', 'second'], submitted['other_list']
    document.css('.missing-time-cron-row')[1].remove
    assert_equal [rows[0], rows[2], rows[3]], TaTeamSetting.missing_time_schedules(encode.call)
    document.css('.missing-time-cron-row').each(&:remove)
    assert_empty TaTeamSetting.missing_time_schedules(encode.call)
  end

  def test_next_run_excludes_inactive_rows_and_includes_monthly
    from = Time.utc(2026, 10, 9)
    inactive = settings([row('0 1 * * *', weekly: false)])
    assert_equal Time.utc(2026, 11, 1, 12, 30), Scheduler.next_run_at(settings: inactive, from_time: from).utc
    assert_equal Time.utc(2026, 10, 9, 8), Scheduler.next_run_at(settings: settings([row('0 8 * * * UTC', weekly: false, daily: true)]), from_time: from).utc
    assert_nil Scheduler.next_run_at(settings: inactive.merge(enabled: false), from_time: from)
  end

  def test_cron_callbacks_dispatch_each_selected_mode_and_refresh_removes_old_jobs
    rows = [row('0 18 * * 5'), row('0 18 * * *', weekly: false, daily: true), row('0 8 * * 1', daily: true), row('0 9 * * *', weekly: false)]
    Setting.plugin_redmine_time_analytics = { 'missing_time_schedules' => rows }
    fake = FakeScheduler.new
    Scheduler.instance_variable_set(:@scheduler, fake)
    Scheduler.instance_variable_set(:@jobs, [])
    calls = []
    original = Scheduler.method(:run_notification!)
    Scheduler.define_singleton_method(:run_notification!) { |period: nil| calls << period }
    Scheduler.send(:schedule_current!)
    assert_equal 4, fake.jobs.size # Three active rows plus monthly.
    fake.jobs.each(&:fire)
    assert_equal [:weekly, :daily, :weekly, :daily, :monthly], calls
    Setting.plugin_redmine_time_analytics = { 'missing_time_enabled' => '0' }
    Scheduler.send(:schedule_current!)
    assert fake.jobs.all?(&:unscheduled)
    assert_empty Scheduler.instance_variable_get(:@jobs)
  ensure
    Scheduler.define_singleton_method(:run_notification!, original) if original
    Scheduler.singleton_class.send(:private, :run_notification!)
  end

  def test_weekly_and_daily_send_separate_emails_only_when_missing
    travel_to Time.utc(2026, 10, 9, 12)
    service = LookupService.new(settings: settings)
    service.missing = { 'Engineering' => { 'Member' => [Date.new(2026, 10, 9)] } }
    [:weekly, :daily].each { |period| assert service.notify_missing_time!(period: period).sent }
    assert_equal [:weekly, :daily], MissingTimeMailer.deliveries.map { |mail| mail[:period_type] }
    assert_equal [Date.new(2026, 10, 5)..Date.new(2026, 10, 9), Date.new(2026, 10, 9)..Date.new(2026, 10, 9)], MissingTimeMailer.deliveries.map { |mail| mail[:date_range] }
    service.missing = {}
    refute service.notify_missing_time!(period: :daily).sent
    assert_equal 2, MissingTimeMailer.deliveries.size
    service.missing = { 'Engineering' => { 'Member' => [Date.new(2026, 10, 9)] } }
    MissingTimeMailer.fail_delivery = true
    result = service.notify_missing_time!(period: :weekly)
    refute result.sent
    assert_match(/SMTP unavailable/, result.errors.first)
  end

  def test_email_subjects_describe_selected_periods
    template = RedmineTimeAnalytics::MissingTimeEmailTemplate
    assert_equal 'Missing Time Entries for the Month of December 2025', template.subject_for(Date.new(2025, 12, 1)..Date.new(2025, 12, 31), :monthly)
    assert_equal 'Missing Time Entries for October 9, 2026', template.subject_for(Date.new(2026, 10, 9)..Date.new(2026, 10, 9), :daily)
    assert_equal 'Missing Time Entries for the Week of October 5–9, 2026', template.subject_for(Date.new(2026, 10, 5)..Date.new(2026, 10, 9), :weekly)
  end

  def test_disabled_or_skipped_delivery_never_reports_sent
    travel_to Time.utc(2026, 10, 9, 12)
    service = LookupService.new(settings: settings)
    service.missing = { 'Engineering' => { 'Member' => [Date.new(2026, 10, 9)] } }
    MissingTimeMailer.perform_deliveries = false
    result = service.notify_missing_time!(period: :weekly)
    refute result.sent
    assert_match(/Email delivery is disabled/, result.errors.first)
    assert_empty MissingTimeMailer.deliveries
    MissingTimeMailer.perform_deliveries = true
    MissingTimeMailer.skip_delivery = true
    result = service.notify_missing_time!(period: :daily)
    refute result.sent
    assert_match(/Email delivery was skipped/, result.errors.first)
    assert_empty MissingTimeMailer.deliveries
  end
end
