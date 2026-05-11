#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'logger'
require 'active_support'
require 'active_support/core_ext'

Time.zone = 'UTC'

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
require_relative '../lib/redmine_time_analytics/leave_sync_service'

def assert(condition, message)
  raise "Assertion failed: #{message}" unless condition
end

def assert_equal(expected, actual, message)
  raise "Assertion failed: #{message}. Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

User.seed([User.new(id: 14, mail: 'arshana@entgra.io')])

parser = RedmineTimeAnalytics::LeaveEmailParser.new
body_priority = parser.parse(
  message: {
    from: 'Arshana Atapattu <arshana@entgra.io>',
    to: 'vacation-group@entgra.io',
    subject: 'Re: Half day leave(Evening) - 29.01.2026',
    body: "Hi all,\n\nPlease note that this leave is shifted to next week(05.02.2026) and it will be a full day leave.\n",
    sent_at: Time.zone.parse('2026-01-28 19:03:00')
  },
  recipient_email: 'vacation-group@entgra.io'
)

assert_equal(Date.new(2026, 2, 5), body_priority.leave_dates.first, 'body date should override the older subject date')
assert_equal(:body, body_priority.date_source, 'body date should be the chosen source')

def sync_case(thread_id:, original_date:, shifted_date:, first_sent_at:, second_sent_at:, third_sent_at:, second_body:, third_body:)
  recipient = 'vacation-group@entgra.io'
  subject = "Half day leave(Evening) - #{original_date.strftime('%d.%m.%Y')}"

  messages = [
    {
      message_id: "#{thread_id}-m1",
      thread_id: thread_id,
      from: 'Arshana Atapattu <arshana@entgra.io>',
      to: recipient,
      subject: subject,
      sent_at: first_sent_at,
      body: "Hi all,\n\nPlease note the #{subject} due to a personal commitment.\n\nBest regards,\nArshana"
    },
    {
      message_id: "#{thread_id}-m2",
      thread_id: thread_id,
      from: 'Arshana Atapattu <arshana@entgra.io>',
      to: recipient,
      subject: subject,
      sent_at: second_sent_at,
      body: second_body
    },
    {
      message_id: "#{thread_id}-m3",
      thread_id: thread_id,
      from: 'Arshana Atapattu <arshana@entgra.io>',
      to: recipient,
      subject: subject,
      sent_at: third_sent_at,
      body: third_body
    }
  ]

  service = RedmineTimeAnalytics::LeaveSyncService.new(settings: { recipient_email: recipient })
  result = service.sync_messages!(messages: messages, mode: :push, recipient_email: recipient)

  assert_equal(3, result.processed_count, "#{thread_id} processed count")
  assert_equal(3, result.imported_count, "#{thread_id} imported count should be message-level")
  assert_equal(0, result.flagged_count, "#{thread_id} flagged count")

  user_id = 14
  records = TaLeaveRecord.confirmed_for(user_id: user_id, thread_id: thread_id)
  assert_equal(1, records.length, "#{thread_id} should keep one final confirmed record")
  record = records.first
  assert_equal(shifted_date, record.leave_date, "#{thread_id} should keep shifted date after final reply")
  assert_equal(1.0, record.leave_fraction.to_f, "#{thread_id} should apply full-day update from final reply")

  stale_record_exists = records.any? { |item| item.leave_date == original_date }
  assert(!stale_record_exists, "#{thread_id} should not keep original stale date")
end

TaLeaveRecord.reset!

sync_case(
  thread_id: 'case-1',
  original_date: Date.new(2026, 1, 29),
  shifted_date: Date.new(2026, 2, 5),
  first_sent_at: Time.zone.parse('2026-01-20 11:29:00'),
  second_sent_at: Time.zone.parse('2026-01-28 19:03:00'),
  third_sent_at: Time.zone.parse('2026-02-05 08:32:00'),
  second_body: "Hi all,\n\nPlease note that this leave is shifted to next week(05.02.2026) and it will be a full day leave.\n",
  third_body: "Hi all,\n\nReminder on the body of the email.\nPlease note this is a full day leave.\n\nBest regards,\nArshana"
)

sync_case(
  thread_id: 'case-2',
  original_date: Date.new(2026, 1, 30),
  shifted_date: Date.new(2026, 2, 6),
  first_sent_at: Time.zone.parse('2026-01-20 11:30:00'),
  second_sent_at: Time.zone.parse('2026-01-28 19:04:00'),
  third_sent_at: Time.zone.parse('2026-02-06 07:22:00'),
  second_body: "Hi all,\n\nPlease note this leave also shifted to next week(06.02.2026)(evening).\n\nBest regards,\nArshana",
  third_body: "Hi all,\n\nReminder on the previous mail body.\nPlease note this will be a full day leave.\n\nBest regards,\nArshana"
)

puts 'Leave sync thread update regression checks passed.'
