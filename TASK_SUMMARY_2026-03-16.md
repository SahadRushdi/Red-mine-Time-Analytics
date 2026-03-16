# Overview
Updated the **My Time** summary cards to match the visual style and behavior of **My Work Log** cards. Removed comparison/target-style messaging and removed the Best/Lightest cards and their now-unused dashboard wiring.

# Code Changes
- Updated `app/views/time_analytics/individual_dashboard.html.erb`:
  - Replaced the old 5-card metric grid with `ts-summary-cards-row` / `ts-summary-card` style cards.
  - Removed **Best Day/Week/Month** and **Lightest Day/Week/Month** cards.
  - Removed Total Hours card progress bar and comparison text (`vs last week`, weekly target bar/percentage).
  - Removed Daily/Weekly/Monthly Average comparison and target text.
  - Updated Active Days card to show only count (`@active_days_count`) without `x/5`, perfect/all-active labels, or zero-day messaging.
  - Added **Issues Worked** card to My Time cards row.
- Updated `app/controllers/time_analytics_controller.rb`:
  - Added `@issues_worked_count` (distinct issues with logs in selected range).
  - Added `@active_days_count` (distinct logged days with `hours > 0`).
  - Removed max/min period and period-count assignments used by removed cards.
- Follow-up card alignment update in `app/views/time_analytics/individual_dashboard.html.erb`:
  - Reordered summary cards to **1,4,2,3** (Total Hours → Issues Worked → Average → Active Days).
  - Updated **Issues Worked** icon styling to the same blue treatment used in My Work Log (`#eef2ff` background, `#6366f1` icon).
  - Updated **Average** card icon to a growth-style trend icon.
- Active Days denominator fix:
  - Updated `app/controllers/time_analytics_controller.rb` so `@active_days_count` now uses working days for the selected range (`calculate_working_days_count`), matching the Daily Average denominator.
  - Updated `app/views/time_analytics/individual_dashboard.html.erb` summary view rows to compute `avg/active day` using `@active_days_count` instead of calendar days (`@to - @from + 1`).
- Summary/detail and table-header cleanup:
  - Removed the `minutes · avg/active day` subtext rows from all My Time summary views in `app/views/time_analytics/individual_dashboard.html.erb`.
  - Removed table header rows for both Logged and Unlogged tabs in `app/views/time_entry_panel/index.html.erb`.
- Expanded date-section indentation fix:
  - Updated `app/views/time_entry_panel/index.html.erb` so expanded issue rows are wrapped with a left blue guide border and left padding (`border-l-4 border-blue-300 pl-4`) to align issue content with the date-section guide line.
- My Time Issue summary style parity update:
  - Updated `app/views/time_analytics/individual_dashboard.html.erb` (Issue tab → Summary view) to render issue rows using the same visual pattern as My Work Log:
    - Tracker badge (`ts-tracker-badge`) with status color script support.
    - Bold black Issue ID link.
    - Black subject link (non-bold) with blue hover state.

# Verification Notes
- Ran Tailwind build successfully:
  - `npm run build`
- Ran existing standalone Ruby test successfully:
  - `ruby test/test_working_days.rb`
- Result: build/test commands completed with exit code `0`.
- Follow-up verification: `ruby test/test_working_days.rb` completed with exit code `0`.
- Active Days fix verification: `ruby test/test_working_days.rb` completed with exit code `0`.
- UI cleanup verification: `ruby test/test_working_days.rb` completed with exit code `0`.
- Indentation fix verification:
  - `npm run build` completed successfully.
  - `ruby test/test_working_days.rb` completed with exit code `0`.
- Issue summary style verification: `ruby test/test_working_days.rb` completed with exit code `0`.

# Next Steps
- Validate the My Time page in Redmine UI for spacing and icon feel across filters (`last week`, `this week`, `custom`) and groupings (`daily`, `weekly`, `monthly`).
