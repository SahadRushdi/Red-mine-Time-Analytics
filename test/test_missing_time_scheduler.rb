#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone regression test for the missing-time monthly compliance reminder.
#
# Bug: the monthly "last Friday of the month" reminder cron ('0 18 * * 5') never actually fired at
# 18:00 local time. Root cause: Rufus::Scheduler's `timezone:` constructor option is NOT inherited
# by individual #cron jobs - Rufus::Scheduler::CronJob#initialize parses the cron line with
# `Fugit::Cron.do_parse(cronline)` and never threads the scheduler's own timezone option into that
# call (see rufus-scheduler's lib/rufus/scheduler/jobs_repeat.rb). A cron string with no embedded
# zone is parsed with @zone/@timezone == nil, and Fugit then falls back to UTC. So '0 18 * * 5'
# was actually scheduled for 18:00 UTC = 23:30 IST, not 18:00 IST - it silently fired 5.5 hours
# late every time, which nobody was awake to notice. Every other (working) cron in this plugin
# already embeds its own zone in the string (e.g. "50 15 * * 5 Asia/Kolkata"); the monthly cron is
# now built the same way via MissingTimeScheduler.monthly_cron(timezone).
#
# This script mocks just enough (Setting/Rails-free) to load the two plain-Ruby lib files and
# exercise the pure date/cron logic without a Rails runtime.

# Force UTC as the "no explicit zone" fallback, matching Redmine's actual deployment default
# (Rails config.time_zone = UTC) - this is exactly why a cron with no embedded zone is dangerous:
# it silently resolves against UTC, not the server's local time. Setting this explicitly also keeps
# the test deterministic regardless of the machine it runs on.
ENV['TZ'] = 'UTC'

require 'date'
require 'fugit'

# Minimal ActiveSupport-style shims used by missing_time_scheduler.rb (blank?/presence).
class NilClass
  def blank?
    true
  end
end

class String
  def blank?
    strip.empty?
  end

  def presence
    blank? ? nil : self
  end
end

class Array
  def blank?
    empty?
  end
end

# Stand-in for the real (ActiveRecord-backed) TaTeamSetting - only the constant
# MissingTimeScheduler#monthly_cron falls back to when no timezone is supplied.
class TaTeamSetting
  DEFAULT_MISSING_TIME_TIMEZONE = 'Asia/Kolkata'
end

require_relative '../lib/redmine_time_analytics/missing_time_scheduler'
require_relative '../lib/redmine_time_analytics/missing_time_notification_service'

failures = []

def check(failures, description, expected, actual)
  if expected == actual
    puts "  PASS: #{description}"
  else
    puts "  FAIL: #{description} (expected #{expected.inspect}, got #{actual.inspect})"
    failures << description
  end
end

puts '=' * 60
puts 'Missing Time Scheduler - Monthly Reminder Regression Test'
puts '=' * 60

scheduler = RedmineTimeAnalytics::MissingTimeScheduler

# Test 1: the bug, reproduced directly - a bare cron string (no embedded timezone) is parsed by
# Fugit with no zone at all, so Rufus has nothing to translate the wall-clock time by.
puts "\nTest 1: reproducing the bug - a bare cron string has no timezone"
bare_line = Fugit::Cron.parse(scheduler::MONTHLY_REMINDER_TIME)
check(failures, "bare '0 18 * * 5' parses with a nil zone (the actual bug)", nil, bare_line.zone)

# Test 2: the fix - MissingTimeScheduler.monthly_cron embeds the timezone in the string itself,
# exactly like every other (working) cron in this plugin already does.
puts "\nTest 2: the fix - monthly_cron embeds the configured timezone in the cron string"
fixed_cron = scheduler.monthly_cron('Asia/Kolkata')
check(failures, 'monthly_cron appends the timezone to the base time', '0 18 * * 5 Asia/Kolkata', fixed_cron)
fixed_line = Fugit::Cron.parse(fixed_cron)
check(failures, 'the fixed cron line now has a real zone', 'Asia/Kolkata', fixed_line.zone)

# Test 3: falls back to the plugin default timezone when none is configured.
puts "\nTest 3: monthly_cron falls back to the default timezone"
check(failures, 'blank timezone falls back to Asia/Kolkata', '0 18 * * 5 Asia/Kolkata', scheduler.monthly_cron(''))
check(failures, 'nil timezone falls back to Asia/Kolkata', '0 18 * * 5 Asia/Kolkata', scheduler.monthly_cron(nil))

# Test 4: regression - prove the actual scheduled instant moves by 5.5 hours (IST offset) once the
# timezone is embedded, for the exact same wall-clock date. This is the concrete "23:30 vs 18:00"
# discrepancy that explained why the reminder looked like it never ran.
puts "\nTest 4: regression - the fix changes WHEN the job actually fires, not just how it looks"
from_time = Time.utc(2026, 7, 31, 0, 0, 0) # midnight UTC on the last Friday of July 2026
buggy_next = bare_line.next_time(from_time)
fixed_next = fixed_line.next_time(from_time)
buggy_utc = Time.at(buggy_next.to_i).utc
fixed_utc = Time.at(fixed_next.to_i).utc
puts "  Buggy (no zone) next fire, in UTC:   #{buggy_utc}"
puts "  Fixed (Asia/Kolkata) next fire, in UTC: #{fixed_utc}"
check(failures, 'the buggy cron fires at 18:00 UTC (i.e. 23:30 IST - not what anyone configured)',
      Time.utc(2026, 7, 31, 18, 0, 0), buggy_utc)
check(failures, 'the fixed cron fires at 12:30 UTC (i.e. 18:00 IST - the intended time)',
      Time.utc(2026, 7, 31, 12, 30, 0), fixed_utc)
check(failures, 'fixing the timezone moves the fire time 5.5 hours earlier',
      5.5 * 3600, buggy_next.to_i - fixed_next.to_i)

# Test 5: last_friday_of_month? gate - the exact scenario from the bug report (July 31, 2026, Friday).
puts "\nTest 5: last_friday_of_month? gate matches the reported date"
service = RedmineTimeAnalytics::MissingTimeNotificationService.allocate # skip initialize (needs TaTeamSetting/AR)
check(failures, 'July 31, 2026 (Friday) is the last Friday of July', true, service.send(:last_friday_of_month?, Date.new(2026, 7, 31)))
check(failures, 'July 24, 2026 (Friday) is NOT the last Friday of July', false, service.send(:last_friday_of_month?, Date.new(2026, 7, 24)))
check(failures, 'a Thursday is never treated as the monthly gate', false, service.send(:last_friday_of_month?, Date.new(2026, 7, 30)))

# Test 6: last_friday_of_month? across months with different Friday counts.
puts "\nTest 6: last_friday_of_month? across months with different Friday counts"
check(failures, 'Jan 30, 2026 is the last Friday of January (5-Friday month)', true, service.send(:last_friday_of_month?, Date.new(2026, 1, 30)))
check(failures, 'Feb 27, 2026 is the last Friday of February (4-Friday month)', true, service.send(:last_friday_of_month?, Date.new(2026, 2, 27)))
check(failures, 'Feb 20, 2026 is NOT the last Friday of February', false, service.send(:last_friday_of_month?, Date.new(2026, 2, 20)))

puts "\n" + '=' * 60
if failures.empty?
  puts 'Test Complete! All checks passed.'
else
  puts "Test Complete! #{failures.size} check(s) FAILED:"
  failures.each { |f| puts "  - #{f}" }
end
puts '=' * 60

exit(failures.empty? ? 0 : 1)
