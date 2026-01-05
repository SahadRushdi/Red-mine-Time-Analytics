# Quick Start Guide: Sri Lankan Working Days Implementation

## Installation (3 steps)

### 1. Install gems
```bash
cd /home/sahad-rushdi/redmine
bundle install
```

### 2. Restart Redmine
```bash
# For WEBrick
# Press Ctrl+C to stop, then:
bundle exec rails server -e production

# For Passenger
touch tmp/restart.txt

# For Systemd
sudo systemctl restart redmine
```

### 3. Verify
```bash
bundle list | grep -E "business_time|holidays"
```

## Quick Test

1. Navigate to: **Time Analytics → Individual Dashboard**
2. Log some time entries across a week (including weekend)
3. Check the "Avg. Daily" statistic in the summary section
4. Verify weekends are excluded from the average calculation

## What Changed?

### Before:
```
Average = Total Hours ÷ Days with Entries
```

### After:
```
Average = Total Hours ÷ Working Days (Mon-Fri, excluding holidays)
```

## Files Created/Modified

✅ **NEW:** `Gemfile` - Added business_time and holidays gems
✅ **NEW:** `config/initializers/business_time.rb` - Holiday configuration  
✅ **MODIFIED:** `app/controllers/time_analytics_controller.rb` - New calculation logic

## Example Calculation

**Scenario:** Time entries from Jan 1-10, 2024
- Calendar days: 10
- Weekends: 4 days (Sat-Sun × 2)
- Working days: 6
- Total hours: 30 hours
- **Old average:** 30 ÷ 10 = 3.0 hours/day
- **New average:** 30 ÷ 6 = 5.0 hours/day ✓

## Troubleshooting

**Gems not found?**
```bash
cd /home/sahad-rushdi/redmine
bundle install --path vendor/bundle
bundle exec rails server
```

**Need to test in Rails console?**
```bash
cd /home/sahad-rushdi/redmine
bundle exec rails console production

# Test a date
require 'business_time'
Date.new(2024, 1, 6).workday?  # Saturday -> false
Date.new(2024, 1, 8).workday?  # Monday -> true
```

**Check Sri Lankan holidays:**
```ruby
# In Rails console
require 'holidays'
Holidays.on(Date.new(2024, 2, 4), :lk)  # Independence Day
```

## Supported Sri Lankan Holidays

✅ Weekends (Saturday, Sunday)
✅ Independence Day (Feb 4)
✅ All Poya Days (monthly Buddhist observances)
✅ Sinhala & Tamil New Year
✅ May Day, Christmas, Good Friday
✅ Islamic holidays (Eid-ul-Fitr, Eid-ul-Adha, Milad-un-Nabi)
✅ Hindu holidays (Deepavali, Thai Pongal)
✅ Other mercantile holidays

## Need More Details?

See: `WORKING_DAYS_IMPLEMENTATION.md` for comprehensive documentation

## Rollback (if needed)

1. Delete: `Gemfile`
2. Restore old method in controller (see WORKING_DAYS_IMPLEMENTATION.md)
3. Run: `bundle install`
4. Restart Redmine
