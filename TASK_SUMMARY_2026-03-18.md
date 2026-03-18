## Overview
Fixed the broken **My Time** page chart and summary-card area on `team_dashboard` by aligning it with the working implementation from `main` and removing remaining pie-chart code paths.

## Code Changes
- Restored `app/views/time_analytics/individual_dashboard.html.erb` to the `main` branch version to remove bad merge artifacts that had injected mismatched HTML/CSS/JS blocks into the page structure.
- Updated `app/controllers/time_analytics_controller.rb`:
  - Removed duplicate variable reassignments in `individual_dashboard` and `export_csv` that were overriding selected user/view context.
  - Removed obsolete pie-chart code:
    - Deleted `generate_pie_chart_data`.
    - Removed `when 'pie'` branch from `generate_member_pivot_chart_data`.

## Verification Notes
- Ran `ruby test/test_working_days.rb` successfully.
- Ran `npm run build` successfully (Tailwind build completed).
- Confirmed scope is limited to:
  - `app/views/time_analytics/individual_dashboard.html.erb`
  - `app/controllers/time_analytics_controller.rb`

## Next Steps
- Validate My Time page visually in Redmine for:
  - Summary cards rendering
  - Main chart switching (bar/line)
  - Donut section rendering
- Proceed to My Team page fixes next.
