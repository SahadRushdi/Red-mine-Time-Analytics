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

puts "\n" + "=" * 60
puts "Test Complete!"
puts "=" * 60
