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
require_relative '../lib/redmine_time_analytics/leave_providers/base_provider'
require_relative '../lib/redmine_time_analytics/leave_providers/gmail_base_provider'

def assert(condition, message)
  raise "Assertion failed: #{message}" unless condition
end

def assert_equal(expected, actual, message)
  raise "Assertion failed: #{message}. Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

class HistoricalWindowProvider < RedmineTimeAnalytics::LeaveProviders::GmailBaseProvider
  Response = Struct.new(:messages, :next_page_token, keyword_init: true)
  MessageRef = Struct.new(:id, keyword_init: true)

  attr_reader :queries

  def initialize(messages_by_id)
    @messages_by_id = messages_by_id
    @queries = []
  end

  private

  def gmail_service
    self
  end

  public

  def list_user_messages(_user, q:, max_results:, page_token:)
    @queries << q
    Response.new(messages: @messages_by_id.keys.map { |id| MessageRef.new(id: id) }, next_page_token: nil)
  end

  def build_message_payload(message_id)
    @messages_by_id[message_id]
  end

  def authorization
    nil
  end
end

window_provider = HistoricalWindowProvider.new(
  'in-range' => {
    message_id: 'in-range',
    thread_id: 'thread-1',
    from: 'Inosh Perera <inosh@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave - 2026/04/17',
    sent_at: Time.zone.parse('2026-04-17 08:00:00'),
    body: 'Leave request'
  },
  'out-of-range' => {
    message_id: 'out-of-range',
    thread_id: 'thread-2',
    from: 'Inosh Perera <inosh@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave - 2026/05/10',
    sent_at: Time.zone.parse('2026-05-10 08:00:00'),
    body: 'Leave request'
  }
)
historical_window = window_provider.fetch_messages(
  mode: :historical,
  recipient_email: 'vacation-group@entgra.io',
  historical_start_date: Date.new(2026, 4, 1),
  historical_end_date: Date.new(2026, 4, 30),
  synced_after: nil
)
assert(window_provider.queries.first.include?('after:2026/04/01'), 'historical sync should include the start date in the Gmail query')
assert(window_provider.queries.first.include?('before:2026/05/01'), 'historical sync should add an exclusive before date when an end date is provided')
assert_equal(1, historical_window.length, 'historical sync with an end date should stay within the requested window')
assert_equal(Date.new(2026, 4, 17), historical_window.first[:sent_at].to_date, 'historical window should keep the in-range message')

start_only_provider = HistoricalWindowProvider.new(
  'in-range' => {
    message_id: 'in-range',
    thread_id: 'thread-1',
    from: 'Inosh Perera <inosh@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave - 2026/04/17',
    sent_at: Time.zone.parse('2026-04-17 08:00:00'),
    body: 'Leave request'
  }
)
start_only_provider.fetch_messages(
  mode: :historical,
  recipient_email: 'vacation-group@entgra.io',
  historical_start_date: Date.new(2026, 4, 1),
  historical_end_date: nil,
  synced_after: nil
)
assert(!start_only_provider.queries.first.include?('before:'), 'historical sync without an end date should not add a before clause')

User.seed([
  User.new(id: 13, mail: 'inosh@entgra.io'),
  User.new(id: 14, mail: 'arshana@entgra.io'),
  User.new(id: 15, mail: 'sandali@example.com'),
  User.new(id: 16, mail: 'oshani@entgra.io'),
  User.new(id: 17, mail: 'viranga@entgra.io'),
  User.new(id: 18, mail: 'yumeth@entgra.io'),
  User.new(id: 19, mail: 'thushara@entgra.io'),
  User.new(id: 20, mail: 'dhishan@entgra.io'),
  User.new(id: 21, mail: 'pahansith@entgra.io'),
  User.new(id: 22, mail: 'rajitha@entgra.io')
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

case1_multi_list_result = ai_live_extractor.parse(
  message: {
    from: 'Inosh Perera <inosh@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave - 9, 10, 16, 17 April 2026',
    body: 'Hi all,\n\nPlease note I will be $subject due to personal commitments.\n',
    sent_at: Time.zone.parse('2026-04-01 12:26:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, case1_multi_list_result.status, 'comma-list request should stay confirmed')
assert_equal(4, case1_multi_list_result.leave_dates.length, 'comma-list request should keep all four requested dates')

case2_sick_result = ai_live_extractor.parse(
  message: {
    from: 'Pahansith Goonetilleke <pahansith@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Sick leave - 28/04/26',
    body: "Please note the $subject due to migraine.\n\nRegards,\n/Pahansith.",
    sent_at: Time.zone.parse('2026-04-28 08:02:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, case2_sick_result.status, 'single-date sick leave should stay confirmed')
assert_equal([Date.new(2026, 4, 28)], case2_sick_result.leave_dates, 'single-date sick leave should keep the explicit date')

case3_comma_result = ai_live_extractor.parse(
  message: {
    from: 'Rajitha Kumara <rajitha@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On Leave - 16, 17 April 2026',
    body: "Hi all,\n\nPlease note the $subject due to a family commitment.\n",
    sent_at: Time.zone.parse('2026-04-02 11:04:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, case3_comma_result.status, 'comma list should stay confirmed')
assert_equal(2, case3_comma_result.leave_dates.length, 'comma list should keep both requested dates')

batch_extractor = RedmineTimeAnalytics::AiLeaveExtractor.new(
  settings: {
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
batch_extractor.define_singleton_method(:request_ai_batch!) do |messages:|
  {
    messages.first[:message_id] => {
      'status' => 'confirmed',
      'reason' => 'ai_analyzed',
      'leave_entries' => [{ 'date' => '2026-04-17', 'fraction' => 1.0 }]
    }
  }
end
batch_extractor.define_singleton_method(:request_ai!) do |subject:, body:, primary_body:, sent_at:|
  {
    'status' => 'confirmed',
    'reason' => 'ai_analyzed',
    'leave_entries' => [{ 'date' => '2026-04-20', 'fraction' => 1.0 }]
  }
end
batch_results = batch_extractor.parse_batch(
  messages: [
    {
      message_id: 'batch-1',
      from: 'Thushara Abeykoon <thushara@entgra.io>',
      to: 'vacation-group@entgra.io',
      subject: 'On Leave - 17/04/2026',
      body: 'Please note the subject.',
      sent_at: Time.zone.parse('2026-04-16 09:59:00')
    },
    {
      message_id: 'batch-2',
      from: 'Thushara Abeykoon <thushara@entgra.io>',
      to: 'vacation-group@entgra.io',
      subject: 'On Leave - 20/04/2026',
      body: 'Please note the subject.',
      sent_at: Time.zone.parse('2026-04-16 10:00:00')
    }
  ],
  recipient_email: 'vacation-group@entgra.io',
  chunk_size: 50
)
assert_equal(2, batch_results.length, 'batch parse should return one result for each input email')
assert_equal(Date.new(2026, 4, 17), batch_results[0].leave_dates.first, 'batch result should map first response correctly')
assert_equal(Date.new(2026, 4, 20), batch_results[1].leave_dates.first, 'missing batch response should retry individually')

ampersand_day_ai = ai_live_extractor.parse(
  message: {
    from: 'Thushara Abeykoon <thushara@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On Leave - 17 & 20 April 2026',
    body: 'Hi all, please approve this leave request.',
    sent_at: Time.zone.parse('2026-04-16 09:59:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, ampersand_day_ai.status, 'ampersand multi-day explicit dates should be confirmed')
assert_equal(2, ampersand_day_ai.leave_dates.length, 'ampersand explicit dates should become two leave entries')
assert_equal(Date.new(2026, 4, 17), ampersand_day_ai.leave_dates.first, 'first ampersand date should be preserved')

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
assert_equal(0, cancel_result.leave_dates.length, 'cancelled reply should have empty leave dates')
assert_equal(0.0, cancel_result.leave_fraction, 'cancelled request should have 0.0 fraction')

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

case5_shift_result = ai_live_extractor.parse(
  message: {
    from: 'Viranga Gunarathne <viranga@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Half day leave - 2026/04/23 (Morning)',
    body: "Hi all,\n\nPlease consider this as a full day leave as I’m feeling unwell.\n",
    sent_at: Time.zone.parse('2026-04-23 12:03:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, case5_shift_result.status, 'correction reply should stay confirmed')
assert_equal([Date.new(2026, 4, 23)], case5_shift_result.leave_dates, 'case 5 should keep the original date')
assert_equal(1.0, case5_shift_result.leave_fraction, 'case 5 correction should upgrade to full day')

case6_relative_result = ai_live_extractor.parse(
  message: {
    from: 'Viranga Gunarathne <viranga@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Sick leave - 2026/03/24',
    body: "Hi all,\n\nI'll be on leave tomorrow (24th), since I need to take some rest.\n",
    sent_at: Time.zone.parse('2026-04-23 23:42:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, case6_relative_result.status, 'relative-date reply should stay confirmed')
assert_equal([Date.new(2026, 4, 24)], case6_relative_result.leave_dates, 'case 6 should use the relative body date')

case8_shift_result = ai_live_extractor.parse(
  message: {
    from: 'Arshana Atapattu <arshana@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Half day leave(Evening) - 29.01.2026',
    body: "Hi all,\n\nPlease note that this leave is shifted to next week(05.02.2026) and it will be a full day leave.\n",
    sent_at: Time.zone.parse('2026-01-28 19:03:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, case8_shift_result.status, 'shifted leave should stay confirmed')
assert_equal([Date.new(2026, 2, 5)], case8_shift_result.leave_dates, 'case 8 should replace the old date with the shifted date')
assert_equal(1.0, case8_shift_result.leave_fraction, 'case 8 should be upgraded to full day')

case9_shift_result = ai_live_extractor.parse(
  message: {
    from: 'Arshana Atapattu <arshana@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Half day leave(Evening) - 30.01.2026',
    body: "Hi all,\n\nPlease note this leave also shifted to next week(06.02.2026)(evening).\n",
    sent_at: Time.zone.parse('2026-01-28 19:04:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, case9_shift_result.status, 'shifted leave should stay confirmed')
assert_equal([Date.new(2026, 2, 6)], case9_shift_result.leave_dates, 'case 9 should replace the old date with the shifted date')
assert_equal(0.5, case9_shift_result.leave_fraction, 'case 9 should stay half day')

sent_date_leak_ai = RedmineTimeAnalytics::AiLeaveExtractor.new(
  settings: {
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
sent_date_leak_ai.define_singleton_method(:request_ai!) do |subject:, body:, primary_body:, sent_at:|
  {
    'status' => 'confirmed',
    'reason' => 'ai_analyzed',
    'leave_entries' => [
      { 'date' => sent_at.to_date.to_s, 'fraction' => 1.0 },
      { 'date' => '2026-02-05', 'fraction' => 1.0 }
    ]
  }
end
sent_date_leak_result = sent_date_leak_ai.parse(
  message: {
    from: 'Arshana Atapattu <arshana@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Half day leave(Evening) - 29.01.2026',
    body: "Hi all,\n\nPlease note that this leave is shifted to next week(05.02.2026) and it will be a full day leave.\n",
    sent_at: Time.zone.parse('2026-01-28 19:03:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, sent_date_leak_result.status, 'sent-date leak case should stay confirmed')
assert_equal([Date.new(2026, 2, 5)], sent_date_leak_result.leave_dates, 'sent date should be removed when AI returns it as an extra date')

case10_correction_result = ai_live_extractor.parse(
  message: {
    from: 'Dhishan Rangajith <dhishan@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave - 14/01/2026',
    body: "Hi all,\n\ncorrection - the leave date should be 16/01/2026., not 14/01/2026.\n",
    sent_at: Time.zone.parse('2026-01-14 20:54:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, case10_correction_result.status, 'correction reply should stay confirmed')
assert_equal([Date.new(2026, 1, 16)], case10_correction_result.leave_dates, 'case 10 should replace the original date with the corrected one')

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

case7_ai = RedmineTimeAnalytics::AiLeaveExtractor.new(
  settings: {
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
case7_ai.define_singleton_method(:request_ai!) do |**|
  {
    'status' => 'flagged',
    'reason' => 'ai_model_failed',
    'leave_entries' => []
  }
end
case7_cancel = case7_ai.parse(
  message: {
    from: 'Yumeth Sumathipala <yumeth@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Half-day Leave Today (06/04/2026 Evening)',
    body: "I am cancelling my half-day leave request for this afternoon. The NAITA officer has postponed our meeting, so I will be working for the full day today.",
    sent_at: Time.zone.parse('2026-04-06 08:45:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:cancelled, case7_cancel.status, 'cancellation reply should be classified as cancelled even without an explicit date')
assert_equal(0, case7_cancel.leave_dates.length, 'case 7 cancellation should have empty leave dates')

TaLeaveRecord.reset!
TaLeaveRecord.upsert_from_email!(
  user: User.sorted.find { |user| user.mail == 'yumeth@entgra.io' },
  leave_date: Date.new(2026, 4, 6),
  leave_fraction: 0.5,
  status: 'confirmed',
  sender_email: 'yumeth@entgra.io',
  recipient_email: 'vacation-group@entgra.io',
  source_message_id: 'case7-1',
  source_thread_id: 'case7-thread',
  source_sent_at: Time.zone.parse('2026-04-06 08:25:00'),
  raw_subject: 'Half-day Leave Today (06/04/2026 Evening)',
  raw_body: 'I will be taking a half-day leave this afternoon.',
  sync_mode: 'historical_ai'
)
case7_service = RedmineTimeAnalytics::LeaveSyncService.new(settings: { recipient_email: 'vacation-group@entgra.io' })
case7_service.instance_variable_set(:@extractor, Object.new.tap do |extractor|
  extractor.define_singleton_method(:parse) do |message:, recipient_email:|
    RedmineTimeAnalytics::LeaveEmailParser::Result.new(
      status: :cancelled,
      reason: 'cancelled',
      user: User.sorted.find { |user| user.mail == 'yumeth@entgra.io' },
      leave_dates: [],
      leave_fraction: 0.5,
      leave_entries: [],
      date_source: :ai,
      subject_has_explicit_date: false,
      body_has_explicit_date: false,
      used_sent_fallback: false
    )
  end
end)
case7_service.sync_messages!(
  messages: [
    {
      message_id: 'case7-cancel',
      thread_id: 'case7-thread',
      from: 'Yumeth Sumathipala <yumeth@entgra.io>',
      to: 'vacation-group@entgra.io',
      subject: 'Half-day Leave Today (06/04/2026 Evening)',
      body: "I am cancelling my half-day leave request for this afternoon. The NAITA officer has postponed our meeting, so I will be working for the full day today.",
      sent_at: Time.zone.parse('2026-04-06 08:45:00')
    }
  ],
  mode: :historical,
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(0, TaLeaveRecord.records.length, 'case 7 cancellation should delete the saved half-day leave')

case7_followup = ai_live_extractor.parse(
  message: {
    from: 'Yumeth Sumathipala <yumeth@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Half-day Leave Today (07/04/2026 Evening)',
    body: "Hi team,\n\nI will be taking that half-day leave this afternoon (07/04/2026).\n\n[Quoted text hidden]\nI am cancelling my half-day leave request for this afternoon. The NAITA officer has postponed our meeting, so I will be working for the full day today.\n",
    sent_at: Time.zone.parse('2026-04-07 07:43:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, case7_followup.status, 'follow-up leave request should not be cancelled by hidden quoted text')
assert_equal([Date.new(2026, 4, 7)], case7_followup.leave_dates, 'follow-up leave request should keep the 07/04 date')
assert_equal(0.5, case7_followup.leave_fraction, 'follow-up leave request should remain half day')

hybrid = RedmineTimeAnalytics::HybridLeaveExtractor.new(
  settings: {
    ai_extraction_enabled: true,
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
simple_called = false
ai_called = false
hybrid.instance_variable_set(:@simple_parser, Object.new.tap do |parser|
  parser.define_singleton_method(:parse) do |**|
    simple_called = true
    raise 'simple parser should not handle multi-date subjects'
  end
end)
hybrid.instance_variable_set(:@ai_extractor, Object.new.tap do |parser|
  parser.define_singleton_method(:parse) do |**|
    ai_called = true
    RedmineTimeAnalytics::LeaveEmailParser::Result.new(
      status: :confirmed,
      reason: 'ai_analyzed',
      user: User.sorted.first,
      leave_dates: [Date.new(2026, 4, 9), Date.new(2026, 4, 10), Date.new(2026, 4, 16), Date.new(2026, 4, 17)],
      leave_fraction: 1.0,
      leave_entries: [
        { date: Date.new(2026, 4, 9), fraction: 1.0 },
        { date: Date.new(2026, 4, 10), fraction: 1.0 },
        { date: Date.new(2026, 4, 16), fraction: 1.0 },
        { date: Date.new(2026, 4, 17), fraction: 1.0 }
      ],
      date_source: :ai,
      subject_has_explicit_date: true,
      body_has_explicit_date: false,
      used_sent_fallback: false
    )
  end
end)
hybrid_result = hybrid.parse(
  message: {
    from: 'Inosh Perera <inosh@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'On leave - 9, 10, 16, 17 April 2026',
    body: "Hi all,\n\nPlease note I will be on leave due to personal commitments.\n",
    sent_at: Time.zone.parse('2026-04-01 12:26:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(true, ai_called, 'multi-date subject should be routed to AI')
assert_equal(false, simple_called, 'multi-date subject should not be routed to the simple parser')
assert_equal(4, hybrid_result.leave_dates.length, 'multi-date subject should preserve all requested dates')

ai_fallback = RedmineTimeAnalytics::AiLeaveExtractor.new(
  settings: {
    ai_provider: 'google',
    ai_model: 'gemini-2.0-flash',
    ai_api_key: 'test-key'
  }
)
ai_fallback.define_singleton_method(:request_ai!) do |**|
  raise StandardError, 'RESOURCE_EXHAUSTED'
end
fallback_result = ai_fallback.parse(
  message: {
    from: 'Viranga Gunarathne <viranga@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Sick leave - 2026/03/24',
    body: "Hi all,\n\nI'll be on leave tomorrow (24th), since I need to take some rest.\n",
    sent_at: Time.zone.parse('2026-04-23 23:42:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)
assert_equal(:confirmed, fallback_result.status, 'provider failures should still fall back to the legacy parser')
assert_equal(Date.new(2026, 4, 24), fallback_result.leave_dates.first, 'relative date should resolve to the requested day')

puts 'Hybrid leave extraction checks passed.'
