# frozen_string_literal: true

namespace :redmine_time_analytics do
  desc 'Send weekly low time-log reminders for previous week (Mon-Fri) on Monday/Tuesday'
  task send_weekly_time_log_reminders: :environment do
    force_run = ENV['RTA_FORCE_REMINDER'] == '1'
    result = RedmineTimeAnalytics::WeeklyTimeLogReminder.run!(force_run: force_run)

    if result[:skipped]
      puts "[redmine_time_analytics] Skipped: #{result[:reason]}"
      next
    end

    puts "[redmine_time_analytics] Week: #{result[:week_start]} to #{result[:week_end]}"
    puts "[redmine_time_analytics] Working days: #{result[:working_days]}"
    puts "[redmine_time_analytics] Threshold hours: #{result[:threshold_hours]}"
    puts "[redmine_time_analytics] Users checked: #{result[:users_checked]}"
    puts "[redmine_time_analytics] Users notified: #{result[:users_notified]}"
  end
end
