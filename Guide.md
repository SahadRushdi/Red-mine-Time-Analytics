# Weekly Reminder Testing Guide

## What changed (temporary testing mode)

The weekly reminder currently includes **testing mode** behavior:

1. Email delivery is restricted to only (and only when each user is `<= 20h`):
   - `sahad@entgra.io`
   - `turboturtle2244@gmail.com`
   - `rushdi1823@gmail.com`
2. You can force execution outside Monday/Tuesday using environment variables.
3. The original production logic is kept in code as comments so you can switch back quickly.

---

## 1) Run reminder when starting Rails server

Use:

```bash
RTA_RUN_REMINDER_ON_SERVER_BOOT=1 bundle exec rails server -e production -b 0.0.0.0 -p 3000
```

This triggers the reminder flow once during server boot (forced run).

---

## 2) Run reminder manually any time

Use:

```bash
RTA_FORCE_REMINDER=1 bundle exec rake redmine_time_analytics:send_weekly_time_log_reminders RAILS_ENV=production
```

Without `RTA_FORCE_REMINDER=1`, it keeps the Monday/Tuesday restriction.

---

## 3) Change execution time (cron schedule)

Current cron example (Mon/Tue 08:00):

```cron
0 8 * * 1,2 cd /path/to/redmine && bundle exec rake redmine_time_analytics:send_weekly_time_log_reminders RAILS_ENV=production >> log/weekly_time_log_reminder.log 2>&1
```

Examples:

- Every 5 minutes (testing):
```cron
*/5 * * * * cd /path/to/redmine && RTA_FORCE_REMINDER=1 bundle exec rake redmine_time_analytics:send_weekly_time_log_reminders RAILS_ENV=production >> log/weekly_time_log_reminder.log 2>&1
```

- Daily at 09:30:
```cron
30 9 * * * cd /path/to/redmine && bundle exec rake redmine_time_analytics:send_weekly_time_log_reminders RAILS_ENV=production >> log/weekly_time_log_reminder.log 2>&1
```

---

## 4) Switch back to production behavior

### A) Re-enable strict Monday/Tuesday check only
In:
`lib/redmine_time_analytics/weekly_time_log_reminder.rb`

- Uncomment:
```ruby
# return { skipped: true, reason: 'weekday_not_allowed' } unless eligible_run_day?(today)
```
- Remove/comment the testing line:
```ruby
return { skipped: true, reason: 'weekday_not_allowed' } unless force_run || eligible_run_day?(today)
```

### B) Send to all qualifying users (remove allowlist)
In:
`lib/redmine_time_analytics/weekly_time_log_reminder.rb`

- Uncomment:
```ruby
# users_to_notify
```
- Remove/comment the allowlist filtering line in `filter_users_for_delivery`.

### C) Disable run-on-server-boot trigger
Do not set:
`RTA_RUN_REMINDER_ON_SERVER_BOOT=1`

or remove the `Rails.configuration.to_prepare` reminder block from:
`init.rb`

---

## Files touched for this behavior

- `lib/redmine_time_analytics/weekly_time_log_reminder.rb`
- `lib/tasks/weekly_time_log_reminder.rake`
- `init.rb`
