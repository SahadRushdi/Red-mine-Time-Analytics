#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'logger'
require 'time'

class Object
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end

  def present?
    !blank?
  end

  def presence
    present? ? self : nil
  end
end

class String
  def blank?
    strip.empty?
  end
end

class NilClass
  def blank?
    true
  end
end

class FalseClass
  def blank?
    true
  end
end

class TrueClass
  def blank?
    false
  end
end

class Hash
  def symbolize_keys
    each_with_object({}) do |(key, value), memo|
      memo[key.respond_to?(:to_sym) ? key.to_sym : key] = value
    end
  end
end

class Time
  class << self
    attr_accessor :zone
  end

  def in_time_zone
    self
  end
end

Time.zone = Object.new
class << Time.zone
  def parse(value)
    Time.parse(value.to_s)
  end

  def now
    Time.now
  end

  def at(value)
    Time.at(value)
  end
end

module RedmineTimeAnalytics
  module WorkingDaysCalculator
    def self.working_day?(_date)
      true
    end
  end

  class LeaveFetcherFactory
    class NoopFetcher
      def fetch_messages(**)
        []
      end
    end

    def self.build(_settings)
      NoopFetcher.new
    end
  end
end

class TaTeamSetting
  def self.leave_sync_settings
    { recipient_email: 'vacation-group@entgra.io' }
  end

  def self.update_leave_sync_runtime!(**)
    true
  end
end

class User
  attr_reader :id, :mail

  def initialize(id:, mail:)
    @id = id
    @mail = mail
  end

  class << self
    def seed(users)
      @users = users
    end

    def active
      self
    end

    def sorted
      @users || []
    end
  end
end

class TaLeaveRecord
  Record = Struct.new(
    :user_id,
    :leave_date,
    :leave_fraction,
    :status,
    :sender_email,
    :recipient_email,
    :source_message_id,
    :source_thread_id,
    :source_sent_at,
    keyword_init: true
  )

  class << self
    def reset!
      @records = []
    end

    def records
      @records ||= []
    end

    def upsert_from_email!(attrs)
      user = attrs[:user]
      leave_date = attrs.fetch(:leave_date)
      leave_fraction = attrs.fetch(:leave_fraction).to_f
      status = attrs.fetch(:status, 'confirmed')

      record = records.find do |item|
        item.user_id == user&.id && item.leave_date == leave_date
      end

      if record
        if record.source_sent_at && attrs[:source_sent_at] && record.source_sent_at > attrs[:source_sent_at] && record.status == 'confirmed'
          return record
        end
      else
        record = Record.new
        records << record
      end

      record.user_id = user&.id
      record.leave_date = leave_date
      record.leave_fraction = leave_fraction
      record.status = status
      record.sender_email = attrs[:sender_email]
      record.recipient_email = attrs[:recipient_email]
      record.source_message_id = attrs[:source_message_id]
      record.source_thread_id = attrs[:source_thread_id]
      record.source_sent_at = attrs[:source_sent_at]
      record
    end

    def newer_thread_update_exists?(user_id:, thread_id:, incoming_sent_at:)
      records.any? do |item|
        item.status == 'confirmed' &&
          item.user_id == user_id &&
          item.source_thread_id == thread_id &&
          item.source_sent_at &&
          incoming_sent_at &&
          item.source_sent_at > incoming_sent_at
      end
    end

    def replace_thread_records!(user_id:, thread_id:, incoming_sent_at:, leave_dates:)
      records.delete_if do |item|
        next false unless item.status == 'confirmed' && item.user_id == user_id && item.source_thread_id == thread_id
        next false if incoming_sent_at && item.source_sent_at && item.source_sent_at > incoming_sent_at

        leave_dates.blank? || !leave_dates.include?(item.leave_date)
      end
    end

    def reconcile_thread_entries!(user_id:, thread_id:, incoming_sent_at:, leave_entries:)
      leave_map = Array(leave_entries).each_with_object({}) do |entry, memo|
        memo[entry[:date]] = entry[:fraction].to_f
      end

      records.each do |item|
        next unless item.status == 'confirmed' && item.user_id == user_id && item.source_thread_id == thread_id
        next if incoming_sent_at && item.source_sent_at && item.source_sent_at > incoming_sent_at
        next unless leave_map.key?(item.leave_date)

        item.leave_fraction = leave_map[item.leave_date]
      end
    end

    def cancel_thread_records!(user_id:, thread_id:, incoming_sent_at:, leave_dates:)
      records.delete_if do |item|
        next false unless item.status == 'confirmed' && item.user_id == user_id && item.source_thread_id == thread_id
        next false if incoming_sent_at && item.source_sent_at && item.source_sent_at > incoming_sent_at

        leave_dates.blank? || leave_dates.include?(item.leave_date)
      end
    end

    def cancel_user_dates!(user_id:, leave_dates:)
      return if leave_dates.blank?

      records.delete_if do |item|
        item.status == 'confirmed' && item.user_id == user_id && leave_dates.include?(item.leave_date)
      end
    end

    def latest_thread_entries(user_id:, thread_id:, before_sent_at: nil)
      matches = records.select do |item|
        item.status == 'confirmed' &&
          item.user_id == user_id &&
          item.source_thread_id == thread_id &&
          (before_sent_at.nil? || item.source_sent_at.nil? || item.source_sent_at < before_sent_at)
      end
      return [] if matches.empty?

      latest_sent_at = matches.map(&:source_sent_at).compact.max
      latest_matches = latest_sent_at ? matches.select { |item| item.source_sent_at == latest_sent_at } : matches
      latest_matches.sort_by(&:leave_date).map do |item|
        { date: item.leave_date, fraction: item.leave_fraction.to_f }
      end
    end

    def confirmed_for(user_id:, thread_id:)
      records.select { |item| item.status == 'confirmed' && item.user_id == user_id && item.source_thread_id == thread_id }
    end
  end
end

require_relative '../lib/redmine_time_analytics/leave_email_parser'
require_relative '../lib/redmine_time_analytics/simple_leave_email_parser'
require_relative '../lib/redmine_time_analytics/ai_leave_extractor'
require_relative '../lib/redmine_time_analytics/leave_sync_service'

def assert(condition, message)
  raise "Assertion failed: #{message}" unless condition
end

def assert_equal(expected, actual, message)
  raise "Assertion failed: #{message}. Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

User.seed([
  User.new(id: 14, mail: 'arshana@entgra.io'),
  User.new(id: 15, mail: 'sandali@example.com'),
  User.new(id: 16, mail: 'oshani@entgra.io')
])

simple_parser = RedmineTimeAnalytics::SimpleLeaveEmailParser.new
year_first = simple_parser.parse(
  message: {
    from: 'Sandali Kavishka <sandali@example.com>',
    to: 'vacation-group@entgra.io',
    subject: 'On Leave 2026/04/03',
    body: 'Hi all,\n\nPlease note the subject due to a university exam.\n\nThanks and regards,\nSandali Kavishka',
    sent_at: Time.zone.parse('2026-03-30 18:38:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)

assert_equal(Date.new(2026, 4, 3), year_first.leave_dates.first, 'year-first subject date should be parsed instead of sent date')
assert_equal(:subject, year_first.date_source, 'year-first subject date should come from the subject')
assert_equal(1.0, year_first.leave_fraction, 'simple parser should default to full day')

half_day = simple_parser.parse(
  message: {
    from: 'Arshana Atapattu <arshana@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Half day leave evening 2026/04/04',
    body: 'Hi team',
    sent_at: Time.zone.parse('2026-04-01 09:00:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(0.5, half_day.leave_fraction, 'half-day keywords in subject should produce 0.5 fraction')

ai_extractor = RedmineTimeAnalytics::AiLeaveExtractor.allocate
ai_confirmed = ai_extractor.send(
  :parsed_result,
  {
    'status' => 'flagged',
    'reason' => 'ambiguous',
    'leave_entries' => [{ 'date' => '2026-02-05', 'fraction' => 1.0 }]
  },
  user: User.sorted.first
)
assert_equal(:confirmed, ai_confirmed.status, 'AI results with entries should be treated as confirmed')
assert_equal('ai_analyzed', ai_confirmed.reason, 'AI results with entries should be marked analyzed')

ai_live_extractor = RedmineTimeAnalytics::AiLeaveExtractor.new(
  settings: {
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
ai_live_extractor.define_singleton_method(:request_ai!) do |**|
  {
    'status' => 'flagged',
    'reason' => 'ai_model_failed',
    'leave_entries' => []
  }
end
multi_day_ai = ai_live_extractor.parse(
  message: {
    from: 'Arshana Atapattu <arshana@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave - 16/04/2026 & 17/04/2026',
    body: 'Hi all, please approve this leave request.',
    sent_at: Time.zone.parse('2026-04-10 10:00:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, multi_day_ai.status, 'AI fallback should confirm multi-day explicit dates')
assert_equal(2, multi_day_ai.leave_dates.length, 'multi-day explicit dates should become two leave entries')
assert_equal(Date.new(2026, 4, 16), multi_day_ai.leave_dates.first, 'first multi-day date should be preserved')

comma_day_ai = ai_live_extractor.parse(
  message: {
    from: 'Arshana Atapattu <arshana@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave 28,29 of May 2026',
    body: 'Hi all, please approve this leave request.',
    sent_at: Time.zone.parse('2026-05-01 10:00:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, comma_day_ai.status, 'comma-day multi-day explicit dates should be confirmed')
assert_equal(2, comma_day_ai.leave_dates.length, 'comma-day explicit dates should become two leave entries')

partial_ai = RedmineTimeAnalytics::AiLeaveExtractor.new(
  settings: {
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
partial_ai.define_singleton_method(:request_ai!) do |**|
  {
    'status' => 'confirmed',
    'reason' => 'ai_analyzed',
    'leave_entries' => [{ 'date' => '2026-04-16', 'fraction' => 1.0 }]
  }
end
partial_result = partial_ai.parse(
  message: {
    from: 'Arshana Atapattu <arshana@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave - 16/04/2026 & 17/04/2026',
    body: 'Hi all, please approve this leave request.',
    sent_at: Time.zone.parse('2026-04-10 10:00:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, partial_result.status, 'partial AI result should stay confirmed')
assert_equal(2, partial_result.leave_dates.length, 'partial AI result should expand to both explicit dates')
assert_equal(Date.new(2026, 4, 17), partial_result.leave_dates.last, 'partial AI result should include the second date')

failing_ai = RedmineTimeAnalytics::AiLeaveExtractor.new(
  settings: {
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
failing_ai.define_singleton_method(:request_ai!) do |**|
  raise StandardError, 'RESOURCE_EXHAUSTED'
end
range_result = failing_ai.parse(
  message: {
    from: 'Arshana Atapattu <arshana@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave from 16/04/2026 to 18/04/2026',
    body: 'Hi all, please approve this leave request.',
    sent_at: Time.zone.parse('2026-04-10 10:00:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, range_result.status, 'provider failures should still confirm explicit ranges')
assert_equal(3, range_result.leave_dates.length, 'explicit date ranges should expand to all days')
assert_equal(Date.new(2026, 4, 16), range_result.leave_dates.first, 'range fallback should keep the first date')
assert_equal(Date.new(2026, 4, 18), range_result.leave_dates.last, 'range fallback should keep the last date')

cancel_ai = RedmineTimeAnalytics::AiLeaveExtractor.new(
  settings: {
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
cancel_ai.define_singleton_method(:request_ai!) do |**|
  {
    'status' => 'flagged',
    'reason' => 'ai_model_failed',
    'leave_entries' => []
  }
end
cancel_result = cancel_ai.parse(
  message: {
    from: 'Oshani Silva <oshani@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Half day leave - Morning 2026/04/07',
    body: "Hi all,\n\nPlease note the subject due to a personal commitment.\n\nThis is cancelled as I was able to work.\n",
    sent_at: Time.zone.parse('2026-03-31 09:17:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:cancelled, cancel_result.status, 'latest cancellation reply should override the subject')
assert_equal(1, cancel_result.leave_dates.length, 'cancelled reply should keep the original requested date')
assert_equal(0.5, cancel_result.leave_fraction, 'cancelled half-day request should preserve the half-day fraction')

mixed_ai = RedmineTimeAnalytics::AiLeaveExtractor.new(
  settings: {
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
mixed_ai.define_singleton_method(:request_ai!) do |**|
  {
    'status' => 'flagged',
    'reason' => 'ai_model_failed',
    'leave_entries' => []
  }
end
mixed_result = mixed_ai.parse(
  message: {
    from: 'Oshani Silva <oshani@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On Leave - 06/04/2026 Half Day (Evening) & 16/04/2026, 17/04/2026 (Full Days)',
    body: 'Hi all,\n\nPlease note the subject due to a personal commitment.',
    sent_at: Time.zone.parse('2026-04-06 07:53:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, mixed_result.status, 'mixed fraction request should stay confirmed')
assert_equal(3, mixed_result.leave_dates.length, 'mixed request should expand to three leave dates')
assert_equal(0.5, mixed_result.leave_entries.find { |entry| entry[:date] == Date.new(2026, 4, 6) }[:fraction], 'first date should be half day')
assert_equal(1.0, mixed_result.leave_entries.find { |entry| entry[:date] == Date.new(2026, 4, 16) }[:fraction], 'second date should be full day')
assert_equal(1.0, mixed_result.leave_entries.find { |entry| entry[:date] == Date.new(2026, 4, 17) }[:fraction], 'third date should be full day')

def sync_case(messages:, expected_imported:, expected_flagged:)
  recipient = 'vacation-group@entgra.io'
  service = RedmineTimeAnalytics::LeaveSyncService.new(settings: { recipient_email: recipient })
  result = service.sync_messages!(messages: messages, mode: :push, recipient_email: recipient)

  assert_equal(messages.length, result.processed_count, 'processed count should match message count')
  assert_equal(expected_imported, result.imported_count, 'imported count mismatch')
  assert_equal(expected_flagged, result.flagged_count, 'flagged count mismatch')
end

TaLeaveRecord.reset!

sync_case(
  messages: [
    {
      message_id: 'simple-1',
      thread_id: 'simple-thread',
      from: 'Sandali Kavishka <sandali@example.com>',
      to: 'vacation-group@entgra.io',
      subject: 'On Leave 2026/04/03',
      body: 'Hi all, on leave due to exam.',
      sent_at: Time.zone.parse('2026-03-30 18:38:00')
    }
  ],
  expected_imported: 1,
  expected_flagged: 0
)

sync_case(
  messages: [
    {
      message_id: 'complex-1',
      thread_id: 'complex-thread',
      from: 'Arshana Atapattu <arshana@entgra.io>',
      to: 'vacation-group@entgra.io',
      subject: 'Re: Half day leave(Evening) - 29.01.2026',
      body: "Hi all,\n\nPlease note that this leave is shifted to next week(05.02.2026) and it will be a full day leave.\n",
      sent_at: Time.zone.parse('2026-01-28 19:03:00')
    }
  ],
  expected_imported: 0,
  expected_flagged: 1
)

TaLeaveRecord.reset!
cancel_user = User.sorted.find { |user| user.mail == 'oshani@entgra.io' }
TaLeaveRecord.upsert_from_email!(
  user: cancel_user,
  leave_date: Date.new(2026, 4, 7),
  leave_fraction: 0.5,
  status: 'confirmed',
  sender_email: 'oshani@entgra.io',
  recipient_email: 'vacation-group@entgra.io',
  source_message_id: 'leave-1',
  source_thread_id: 'cancel-thread',
  source_sent_at: Time.zone.parse('2026-03-31 09:17:00'),
  raw_subject: 'Half day leave - Morning 2026/04/07',
  raw_body: 'Please note the subject due to a personal commitment.',
  sync_mode: 'historical_ai'
)
TaLeaveRecord.upsert_from_email!(
  user: cancel_user,
  leave_date: Date.new(2026, 4, 7),
  leave_fraction: 0.5,
  status: 'confirmed',
  sender_email: 'oshani@entgra.io',
  recipient_email: 'vacation-group@entgra.io',
  source_message_id: 'leave-1-reminder',
  source_thread_id: 'cancel-thread',
  source_sent_at: Time.zone.parse('2026-04-07 05:47:00'),
  raw_subject: 'Reminder on Half day leave - Morning 2026/04/07',
  raw_body: 'Reminder on the subject.',
  sync_mode: 'historical_ai'
)

cancel_service = RedmineTimeAnalytics::LeaveSyncService.new(settings: { recipient_email: 'vacation-group@entgra.io' })
cancel_extractor = Object.new
cancel_extractor.define_singleton_method(:parse) do |message:, recipient_email:|
  RedmineTimeAnalytics::LeaveEmailParser::Result.new(
    status: :cancelled,
    reason: 'cancelled',
    user: cancel_user,
    leave_dates: [Date.new(2026, 4, 7)],
    leave_fraction: 0.5,
    leave_entries: [{ date: Date.new(2026, 4, 7), fraction: 0.5 }],
    date_source: :ai,
    subject_has_explicit_date: true,
    body_has_explicit_date: true,
    used_sent_fallback: false
  )
end
cancel_service.instance_variable_set(:@extractor, cancel_extractor)
cancel_service.sync_messages!(
  messages: [
    {
      message_id: 'cancel-1',
      thread_id: 'cancel-thread',
      from: 'Oshani Silva <oshani@entgra.io>',
      to: 'vacation-group@entgra.io',
      subject: 'Half day leave - Morning 2026/04/07',
      body: "This is cancelled as I was able to work.",
      sent_at: Time.zone.parse('2026-04-08 00:38:00')
    }
  ],
  mode: :historical,
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(0, TaLeaveRecord.records.length, 'cancelled leave should be deleted from the database')

puts 'Hybrid leave extraction checks passed.'
