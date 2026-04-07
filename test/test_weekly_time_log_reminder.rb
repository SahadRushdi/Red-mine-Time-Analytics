#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'ostruct'

# Minimal stubs to run outside Redmine runtime
module ActiveSupport
  module Concern; end
end

class Date
  def beginning_of_week
    self - (cwday - 1)
  end
end

module Redmine
  module Utils
    module DateCalculation
    end
  end
end

class Setting
  def self.non_working_week_days
    [6, 7]
  end
end

class User
  STATUS_ACTIVE = 1

  def self.const_defined?(_name)
    true
  end

  def self.joins(*)
    Relation.new
  end

  def self.where(*)
    Relation.new
  end

  class Relation
    def where(*)
      self
    end

    def not(*)
      self
    end

    def order(*)
      [
        OpenStruct.new(id: 1, firstname: 'Sahad', lastname: 'Rushdi', mail: 'sahad@entgra.io'),
        OpenStruct.new(id: 2, firstname: 'Turbo', lastname: 'Turtle', mail: 'turboturtle2244@gmail.com'),
        OpenStruct.new(id: 3, firstname: 'Cara', lastname: 'Fernando', mail: 'cara@example.com')
      ]
    end
  end
end

class Project
  STATUS_ACTIVE = 1
end

class TimeEntry
  def self.joins(*)
    Relation.new
  end

  class Relation
    def where(*)
      self
    end

    def group(*)
      self
    end

    def sum(*)
      {
        1 => 20.0,
        2 => 19.0,
        3 => 23.5
      }
    end
  end
end

class WeeklyTimeLogReminderMailer
  class << self
    attr_reader :last_payload

    def notify_low_time_logs(**kwargs)
      @last_payload = kwargs
      Delivery.new
    end
  end

  class Delivery
    def deliver_now
      true
    end
  end
end

require_relative '../lib/redmine_time_analytics/holidays'
require_relative '../lib/redmine_time_analytics/working_days_calculator'
require_relative '../lib/redmine_time_analytics/weekly_time_log_reminder'

puts '=' * 60
puts 'Weekly Time Log Reminder - Test'
puts '=' * 60

result = RedmineTimeAnalytics::WeeklyTimeLogReminder.run!(today: Date.new(2026, 4, 6))

raise 'Expected task to run on Monday' if result[:skipped]
raise 'Expected previous Monday as start date' unless result[:week_start] == Date.new(2026, 3, 30)
raise 'Expected previous Friday as end date' unless result[:week_end] == Date.new(2026, 4, 3)
raise 'Expected 20-hour threshold' unless result[:threshold_hours] == 20.0
raise 'Expected two notified users (<= 20h)' unless result[:users_notified] == 2

payload = WeeklyTimeLogReminderMailer.last_payload
raise 'Expected mailer payload to be recorded' if payload.nil?
raise 'Expected payload week start mismatch' unless payload[:week_start] == Date.new(2026, 3, 30)
raise 'Expected payload week end mismatch' unless payload[:week_end] == Date.new(2026, 4, 3)

notified_names = payload[:users].map { |u| "#{u[:firstname]} #{u[:lastname]}".strip }
raise 'Expected Sahad to be notified' unless notified_names.include?('Sahad Rushdi')
raise 'Expected Turbo to be notified' unless notified_names.include?('Turbo Turtle')
raise 'Did not expect Cara to be notified' if notified_names.include?('Cara Fernando')

skip_result = RedmineTimeAnalytics::WeeklyTimeLogReminder.run!(today: Date.new(2026, 4, 8), send_email: false)
raise 'Expected Wednesday run to be skipped' unless skip_result[:skipped]

puts 'All assertions passed.'
puts '=' * 60
