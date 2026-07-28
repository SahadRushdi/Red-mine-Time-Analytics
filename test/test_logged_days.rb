#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone test for the "Logged Days / Active Days" badge on the Team Dashboard Members
# summary (TeamAnalyticsController#calculate_member_logged_days).
#
# Runs without a Rails runtime by mocking Setting/Redmine/CustomHoliday, in the same style as
# test_working_days.rb. It mirrors the controller's credit rule so the arithmetic and the
# numerator <= denominator invariant can be verified in isolation from ActiveRecord.

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

# Mock the CustomHoliday model. RedmineTimeAnalytics::Holidays picks this up via defined?(),
# so declaring it here is enough to exercise the holiday branch of working_day_checker.
class CustomHoliday
  HOLIDAY_DATES = [Date.new(2026, 7, 8)].freeze # a Wednesday, so it is not masked by a weekend

  def self.is_holiday?(date)
    HOLIDAY_DATES.include?(date)
  end

  def self.holidays_between(from_date, to_date)
    HOLIDAY_DATES.select { |d| d >= from_date && d <= to_date }
  end
end

require_relative '../lib/redmine_time_analytics/holidays'
require_relative '../lib/redmine_time_analytics/working_days_calculator'

WDC = RedmineTimeAnalytics::WorkingDaysCalculator

failures = []

def check(failures, description, expected, actual)
  if expected == actual
    puts "  PASS: #{description}"
  else
    puts "  FAIL: #{description} (expected #{expected.inspect}, got #{actual.inspect})"
    failures << description
  end
end

# Mirrors TeamAnalyticsController#calculate_member_logged_days. A logged date earns the active-day
# fraction of that date (1.0 - leave_fraction); weekends, holidays and full-day leaves earn
# nothing and are collected separately for the badge tooltip.
def logged_days_and_off_days(logged_dates, leave_fractions, from_date, to_date)
  is_working_day = WDC.working_day_checker(from_date, to_date)
  logged = 0.0
  off_days = []

  logged_dates.each do |date|
    credit = is_working_day.call(date) ? 1.0 - leave_fractions.fetch(date, 0.0) : 0.0

    if credit > 0
      logged += credit
    else
      off_days << date
    end
  end

  [logged.round(2), off_days.sort]
end

# The denominator, unchanged by this fix: working days minus leave day-equivalents, where leave
# falling on a non-working day is ignored (TaLeaveRecord.total_leave_days_for_users).
def active_days(leave_fractions, from_date, to_date)
  is_working_day = WDC.working_day_checker(from_date, to_date)
  leave = leave_fractions.sum { |date, fraction| is_working_day.call(date) ? fraction : 0.0 }
  [WDC.working_days_count(from_date, to_date) - leave, 0].max.round(2)
end

puts "=" * 70
puts "Logged Days / Active Days badge - Test"
puts "=" * 70

# ---------------------------------------------------------------------------
# Test 1: the reported production case (Dhishan Rangajith, Jul 1-26 2026).
# 18 working days; leave 0.5 (Jul 1) + 1.0 (Jul 16) + 0.5 (Jul 20) = 2.0 -> Active Days 16.0.
# He logged on 14 distinct dates, two of which are NOT active days: Sat Jul 4 and the full-leave
# Jul 16. The old numerator counted all 14 and rendered "14/16" (2 days apparently missing) while
# his individual board showed five 0:00 working days.
# ---------------------------------------------------------------------------
puts "\nTest 1: Reported case - Dhishan Rangajith, Jul 01-26 2026"
from = Date.new(2026, 7, 1)
to   = Date.new(2026, 7, 26)

# Neutralise the mock holiday for this test so the range matches production (18 working days).
def CustomHoliday.holidays_between(_from, _to) = []
def CustomHoliday.is_holiday?(_date) = false

dhishan_leave = {
  Date.new(2026, 7, 1)  => 0.5,
  Date.new(2026, 7, 16) => 1.0,
  Date.new(2026, 7, 20) => 0.5
}
dhishan_logged = [1, 2, 3, 4, 6, 7, 8, 9, 10, 13, 14, 15, 16, 17].map { |d| Date.new(2026, 7, d) }

check(failures, "working days in range", 18, WDC.working_days_count(from, to))
check(failures, "Active Days denominator is unchanged at 16.0", 16.0, active_days(dhishan_leave, from, to))

old_numerator = dhishan_logged.size
check(failures, "old numerator counted every logged date", 14, old_numerator)

numerator, off_days = logged_days_and_off_days(dhishan_logged, dhishan_leave, from, to)
check(failures, "new numerator is 11.5", 11.5, numerator)
check(failures, "badge reads 11.5/16", "11.5/16.0", "#{numerator}/#{active_days(dhishan_leave, from, to)}")
check(failures, "off-day logs are Sat Jul 4 and full-leave Jul 16",
      [Date.new(2026, 7, 4), Date.new(2026, 7, 16)], off_days)

# logged + missing must reconstruct Active Days. Missing = Jul 20 (half-leave, 0.5) + Jul 21-24 (4.0).
missing = 0.5 + 4.0
check(failures, "logged + missing == Active Days", 16.0, (numerator + missing).round(2))

# ---------------------------------------------------------------------------
# Test 2: the credit rule, date type by date type.
# ---------------------------------------------------------------------------
puts "\nTest 2: Credit rule per date type"
week_from = Date.new(2026, 7, 1)
week_to   = Date.new(2026, 7, 31)

check(failures, "ordinary working day earns 1.0", [1.0, []],
      logged_days_and_off_days([Date.new(2026, 7, 2)], {}, week_from, week_to))

check(failures, "half-day leave earns 0.5 and is NOT an off-day", [0.5, []],
      logged_days_and_off_days([Date.new(2026, 7, 2)], { Date.new(2026, 7, 2) => 0.5 }, week_from, week_to))

check(failures, "full-day leave earns 0.0 and IS an off-day", [0.0, [Date.new(2026, 7, 2)]],
      logged_days_and_off_days([Date.new(2026, 7, 2)], { Date.new(2026, 7, 2) => 1.0 }, week_from, week_to))

check(failures, "Saturday earns 0.0 and IS an off-day", [0.0, [Date.new(2026, 7, 4)]],
      logged_days_and_off_days([Date.new(2026, 7, 4)], {}, week_from, week_to))

check(failures, "Sunday earns 0.0 and IS an off-day", [0.0, [Date.new(2026, 7, 5)]],
      logged_days_and_off_days([Date.new(2026, 7, 5)], {}, week_from, week_to))

check(failures, "member with no time logs is 0.0", [0.0, []],
      logged_days_and_off_days([], {}, week_from, week_to))

# Restore the mock holiday to exercise the custom-holiday branch.
class CustomHoliday
  def self.is_holiday?(date) = HOLIDAY_DATES.include?(date)
  def self.holidays_between(from_date, to_date) = HOLIDAY_DATES.select { |d| d >= from_date && d <= to_date }
end

check(failures, "custom holiday (Wed Jul 8) earns 0.0 and IS an off-day", [0.0, [Date.new(2026, 7, 8)]],
      logged_days_and_off_days([Date.new(2026, 7, 8)], {}, week_from, week_to))

def CustomHoliday.holidays_between(_from, _to) = []
def CustomHoliday.is_holiday?(_date) = false

# ---------------------------------------------------------------------------
# Test 3: the headline regression - the numerator must never exceed the denominator.
# Each row is [description, logged dates, leave fractions].
# ---------------------------------------------------------------------------
puts "\nTest 3: Invariant - numerator <= denominator (the over-100% bug)"
june_from = Date.new(2026, 6, 1)  # Monday
june_to   = Date.new(2026, 6, 30) # 22 working days, no holidays
all_working = (june_from..june_to).select { |d| WDC.working_day_checker(june_from, june_to).call(d) }
all_weekend = (june_from..june_to).reject { |d| WDC.working_day_checker(june_from, june_to).call(d) }

scenarios = [
  ["logs every working day, no leave", all_working, {}],
  ["logs every working day plus 2 weekends", all_working + all_weekend.first(2), {}],
  ["1 full-leave day, logs the other 21", all_working - [all_working[3]], { all_working[3] => 1.0 }],
  ["1 full-leave day and ALSO logs on it", all_working, { all_working[3] => 1.0 }],
  ["1 half-leave day, logs it", all_working, { all_working[3] => 0.5 }],
  ["1 half-leave day, does NOT log it", all_working - [all_working[3]], { all_working[3] => 0.5 }],
  ["every weekend logged, no working day logged", all_weekend, {}]
]

scenarios.each do |description, logged_dates, leave|
  numerator, = logged_days_and_off_days(logged_dates, leave, june_from, june_to)
  denominator = active_days(leave, june_from, june_to)
  old_numerator = logged_dates.size
  flag = old_numerator > denominator ? "  <- old value exceeded the denominator" : ""
  puts "  #{description}: was #{old_numerator}/#{denominator}, now #{numerator}/#{denominator}#{flag}"
  check(failures, "invariant holds - #{description}", true, numerator <= denominator)
end

# The specific rows the team lead asked about.
numerator, = logged_days_and_off_days(all_working, { all_working[3] => 0.5 }, june_from, june_to)
check(failures, "half-leave day logged renders 21.5/21.5",
      "21.5/21.5", "#{numerator}/#{active_days({ all_working[3] => 0.5 }, june_from, june_to)}")

numerator, = logged_days_and_off_days(all_working - [all_working[3]], { all_working[3] => 0.5 }, june_from, june_to)
check(failures, "half-leave day NOT logged renders 21.0/21.5 (0.5 missing)",
      "21.0/21.5", "#{numerator}/#{active_days({ all_working[3] => 0.5 }, june_from, june_to)}")

# ---------------------------------------------------------------------------
# Test 4: leave recorded on a non-working day must not affect either side.
# ---------------------------------------------------------------------------
puts "\nTest 4: Leave falling on a weekend is ignored by both sides"
weekend_leave = { Date.new(2026, 7, 4) => 1.0 } # Saturday
check(failures, "weekend leave does not reduce Active Days", 18.0, active_days(weekend_leave, from, to))
numerator, off_days = logged_days_and_off_days([Date.new(2026, 7, 2)], weekend_leave, from, to)
check(failures, "weekend leave does not affect the numerator", 1.0, numerator)
check(failures, "weekend leave produces no off-day entry on its own", [], off_days)

puts "\n" + "=" * 70
if failures.empty?
  puts "Test Complete! All checks passed."
else
  puts "Test Complete! #{failures.size} check(s) FAILED:"
  failures.each { |f| puts "  - #{f}" }
end
puts "=" * 70

exit(failures.empty? ? 0 : 1)
