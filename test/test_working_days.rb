#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick test script to verify working days calculation
# This can be run standalone to test the logic

require 'date'

# Mock the Setting class for testing
class Setting
  def self.non_working_week_days
    [6, 7] # Saturday and Sunday
  end
end

# Mock Redmine::Utils::DateCalculation
module Redmine
  module Utils
    module DateCalculation
    end
  end
end

# Load our modules
require_relative '../lib/redmine_time_analytics/holidays'
require_relative '../lib/redmine_time_analytics/working_days_calculator'

puts "=" * 60
puts "Working Days Calculator - Test"
puts "=" * 60

# Test 1: Simple week test
puts "\nTest 1: Simple Week (Dec 30, 2024 - Jan 5, 2025)"
from_date = Date.new(2024, 12, 30)
to_date = Date.new(2025, 1, 5)
working_days = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(from_date, to_date)
total_days = (to_date - from_date).to_i + 1
puts "Total days: #{total_days}"
puts "Working days: #{working_days}"

# Test 2: Check if a date is a holiday (from database)
puts "\nTest 2: Check Holiday from Database"
test_date = Date.new(2025, 1, 13)
is_holiday = RedmineTimeAnalytics::Holidays.holiday?(test_date)
puts "Date: #{test_date}"
puts "Is Holiday: #{is_holiday}"
puts "Note: This checks database, not hardcoded holidays"

# Test 3: Check a specific date
puts "\nTest 3: Check Another Date"
test_date2 = Date.new(2025, 2, 4)
is_holiday = RedmineTimeAnalytics::Holidays.holiday?(test_date2)
is_working = RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(test_date2)
puts "Date: #{test_date2} (#{test_date2.strftime('%A')})"
puts "Is Holiday: #{is_holiday}"
puts "Is Working Day: #{is_working}"

# Test 4: Average hours calculation simulation
puts "\nTest 4: Average Hours Calculation Simulation"
puts "-" * 60
from_date = Date.new(2025, 1, 1)
to_date = Date.new(2025, 1, 31)
total_hours = 150.0
working_days = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(from_date, to_date)
avg_hours = (total_hours / working_days).round(2)
total_days = (to_date - from_date).to_i + 1

puts "Period: #{from_date} to #{to_date}"
puts "Total calendar days: #{total_days}"
puts "Working days: #{working_days}"
puts "Total hours logged: #{total_hours}h"
puts "Average hours per working day: #{avg_hours}h"
puts "Old calculation (all days): #{(total_hours / total_days).round(2)}h"

failures = []

def check(failures, description, expected, actual)
  if expected == actual
    puts "  PASS: #{description}"
  else
    puts "  FAIL: #{description} (expected #{expected.inspect}, got #{actual.inspect})"
    failures << description
  end
end

# Test 5: clamp_to_range - "This Month" (month-to-date) must not extend past today
puts "\nTest 5: clamp_to_range - month-to-date filter clamps a full-month bucket"
month_start = Date.new(2026, 7, 1)
month_end   = Date.new(2026, 7, 31)
filter_from = Date.new(2026, 7, 1)
filter_to   = Date.new(2026, 7, 21) # "today" mid-month
clamped = RedmineTimeAnalytics::WorkingDaysCalculator.clamp_to_range(month_start, month_end, filter_from, filter_to)
check(failures, "clamped start", Date.new(2026, 7, 1), clamped[0])
check(failures, "clamped end (must not go past filter_to)", Date.new(2026, 7, 21), clamped[1])

# Test 6: clamp_to_range - custom range fully inside a month bucket
puts "\nTest 6: clamp_to_range - custom range narrower than the month bucket"
filter_from2 = Date.new(2026, 7, 10)
filter_to2   = Date.new(2026, 7, 20)
clamped2 = RedmineTimeAnalytics::WorkingDaysCalculator.clamp_to_range(month_start, month_end, filter_from2, filter_to2)
check(failures, "clamped start", Date.new(2026, 7, 10), clamped2[0])
check(failures, "clamped end", Date.new(2026, 7, 20), clamped2[1])

# Test 7: clamp_to_range - a complete past month (e.g. "Last Month") is unchanged
puts "\nTest 7: clamp_to_range - complete past month is a no-op"
past_start = Date.new(2026, 6, 1)
past_end   = Date.new(2026, 6, 30)
clamped3 = RedmineTimeAnalytics::WorkingDaysCalculator.clamp_to_range(past_start, past_end, past_start, past_end)
check(failures, "clamped start", past_start, clamped3[0])
check(failures, "clamped end", past_end, clamped3[1])

# Test 8: clamp_to_range - non-overlapping ranges return nil
puts "\nTest 8: clamp_to_range - non-overlapping ranges"
no_overlap = RedmineTimeAnalytics::WorkingDaysCalculator.clamp_to_range(
  Date.new(2026, 8, 1), Date.new(2026, 8, 31), Date.new(2026, 7, 1), Date.new(2026, 7, 21)
)
check(failures, "no overlap returns nil", nil, no_overlap)

# Test 9: Regression - Team Average must use elapsed working days, not the whole calendar
# month, when "This Month" (month-to-date) is selected. Mirrors the production bug: a
# month-to-date filter with 15 elapsed working days must NOT be diluted by using July's ~23
# working days as the denominator.
puts "\nTest 9: Team Average regression (This Month / month-to-date)"
team_size = 39
hours = 3733.383 # 3733:23
leave_days_elapsed = 45.5 # team-wide sum, over the elapsed range only

# Buggy (pre-fix) behavior: working/leave days computed over the FULL calendar month.
full_month_working_days = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(month_start, month_end)
buggy_team_active_days = (full_month_working_days * team_size) - (leave_days_elapsed * full_month_working_days / 15.0)
buggy_average = (hours / buggy_team_active_days).round(2)

# Fixed behavior: clamp to the actual filter range (@from..@to) before computing working/leave days.
elapsed_start, elapsed_end = RedmineTimeAnalytics::WorkingDaysCalculator.clamp_to_range(month_start, month_end, filter_from, filter_to)
elapsed_working_days = RedmineTimeAnalytics::WorkingDaysCalculator.working_days_count(elapsed_start, elapsed_end)
fixed_team_active_days = (elapsed_working_days * team_size) - leave_days_elapsed
fixed_average = (hours / fixed_team_active_days).round(2)

puts "  Full-month working days (buggy denominator basis): #{full_month_working_days}"
puts "  Elapsed working days (fixed denominator basis):     #{elapsed_working_days}"
puts "  Buggy average:  #{buggy_average}h  (diluted by unelapsed days)"
puts "  Fixed average:  #{fixed_average}h"

check(failures, "clamped range uses the 15 elapsed working days from the screenshot", 15, elapsed_working_days)
check(failures, "fixed average is higher than the buggy month-to-date average", true, fixed_average > buggy_average)
check(failures, "fixed team_active_days matches Working Days * Team Size - Leave Days", 539.5, fixed_team_active_days)

# Test 10: Team size must count DISTINCT members, not membership rows — a member who belongs
# to two sub-teams (e.g. Lasantha in both "Automation" and "Manufacturing Automation") must
# only count once toward Team Size, and that deduplicated count is what Average divides by.
puts "\nTest 10: Team size dedup - a member in 2 concurrent teams counts once"
FakeMembership = Struct.new(:user_id, :start_date, :end_date)

period_start = Date.new(2026, 6, 29)
period_end   = Date.new(2026, 7, 5)

team_members = [
  FakeMembership.new(1, Date.new(2026, 1, 1), nil), # Charitha - AI Automation Specialists
  FakeMembership.new(2, Date.new(2026, 1, 1), nil), # Kaif - AI Automation Specialists
  FakeMembership.new(3, Date.new(2026, 1, 1), nil), # Kaveesh - AI Automation Specialists
  FakeMembership.new(4, Date.new(2026, 1, 1), nil), # Sanuka - AI Automation Specialists
  FakeMembership.new(5, Date.new(2026, 1, 1), nil), # Turbo Turtle - AI Automation Specialists
  FakeMembership.new(6, Date.new(2026, 1, 1), nil), # Lasantha - Automation
  FakeMembership.new(6, Date.new(2026, 1, 1), nil), # Lasantha - Manufacturing Automation (2nd membership, same user)
  FakeMembership.new(7, Date.new(2026, 1, 1), nil)  # Sandali - Automation
]

# Old (buggy) behavior: counts membership rows.
buggy_team_size = team_members.count do |m|
  m.start_date <= period_end && (m.end_date.nil? || m.end_date >= period_start)
end

# Fixed behavior: distinct user_ids.
fixed_team_size = team_members
  .select { |m| m.start_date <= period_end && (m.end_date.nil? || m.end_date >= period_start) }
  .map(&:user_id)
  .uniq
  .count

check(failures, "buggy count double-counts Lasantha's 2 memberships", 8, buggy_team_size)
check(failures, "fixed count dedupes to 7 distinct members", 7, fixed_team_size)

# Average must divide by the deduplicated team size, not the raw membership count.
hours = 100.0
working_days = 5
buggy_average = (hours / (working_days * buggy_team_size)).round(2)
fixed_average = (hours / (working_days * fixed_team_size)).round(2)
puts "  Buggy average (team_size=8): #{buggy_average}h"
puts "  Fixed average (team_size=7): #{fixed_average}h"
check(failures, "fixed average uses the deduplicated team size", (100.0 / (5 * 7)).round(2), fixed_average)

puts "\n" + "=" * 60
if failures.empty?
  puts "Test Complete! All checks passed."
else
  puts "Test Complete! #{failures.size} check(s) FAILED:"
  failures.each { |f| puts "  - #{f}" }
end
puts "=" * 60

exit(failures.empty? ? 0 : 1)
