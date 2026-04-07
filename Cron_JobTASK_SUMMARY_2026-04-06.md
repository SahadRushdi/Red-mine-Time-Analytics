# Overview
Implemented a weekly cron-driven reminder flow for low time logs. The plugin checks the previous work week (Monday-Friday), uses existing working-day/holiday logic, and emails users whose logged hours are at or below 20 hours. Added a temporary testing mode to force execution and limit delivery to selected recipients.

# Code Changes
- Added weekly reminder service:
  - `lib/redmine_time_analytics/weekly_time_log_reminder.rb`
  - Default behavior runs only on Monday/Tuesday.
  - Computes previous week window as Monday-Friday.
  - Reuses existing `WorkingDaysCalculator` and holiday path.
  - Uses fixed threshold:
    - `threshold = 20.0`
  - Queries active users and their weekly hours from active projects.
  - Triggers email when users with `hours <= threshold` exist.
  - Added temporary testing allowlist:
    - `sahad@entgra.io`
    - `turboturtle2244@gmail.com`
    - `rushdi1823@gmail.com`
  - Kept production lines commented in code for quick rollback.
  - Fixed production email lookup bug by using Redmine `email_addresses` association instead of `users.mail` column.
  - Added reminder selection diagnostics in Rails log (`[redmine_time_analytics] Weekly reminder selection: ...`) for troubleshooting.

- Added mailer and email template:
  - `app/mailers/weekly_time_log_reminder_mailer.rb`
  - `app/views/weekly_time_log_reminder_mailer/notify_low_time_logs.text.erb`
  - Email content follows requested reminder format and includes listed employees.

- Added rake task for cron execution:
  - `lib/tasks/weekly_time_log_reminder.rake`
  - Task name:
    - `redmine_time_analytics:send_weekly_time_log_reminders`
  - Added env-based force run:
    - `RTA_FORCE_REMINDER=1`

- Holiday/working-day behavior:
  - Reverted to existing plugin holiday source (`CustomHoliday` through `Holidays`).
  - Removed newly introduced custom holiday extension.

- Wired service loading:
  - `lib/redmine_time_analytics.rb`

- Added standalone test script:
  - `test/test_weekly_time_log_reminder.rb`
  - Verifies:
    - Monday execution
    - previous week window resolution (e.g., 2026-04-06 => 2026-03-30..2026-04-03)
    - 20-hour threshold
    - only users with `<= 20h` are included
    - non-Mon/Tue execution is skipped

- Updated documentation:
  - `README.md`
  - Added weekly reminder section with task command and cron example.
  - `Guide.md`
    - Added run-on-server-start testing instructions
    - Added how to change cron timing
    - Added how to switch back to production behavior

- Added server-boot trigger in plugin entrypoint:
  - `init.rb`
  - Executes reminder on boot only when:
    - `RTA_RUN_REMINDER_ON_SERVER_BOOT=1`

# Verification Notes
- `npm run build` completed successfully.
- `ruby test/test_working_days.rb` completed successfully.
- `ruby test/test_weekly_time_log_reminder.rb` completed successfully.

# Next Steps
- Configure system cron on the Redmine host to run the rake task at `0 8 * * 1,2`.
