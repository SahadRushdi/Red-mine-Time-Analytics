## Overview
Fixed the **My Work Log → Unlogged** tab `Log` flow in two steps:
- made the button reliably open inline form
- then updated the Unlogged inline form to match the Logged tab’s Flowbite-style component pattern and interaction style

## Code Changes
- Updated `app/views/time_entry_panel/index.html.erb`:
  - Added an explicit id on the unlogged inline form container:
    - `issue-inline-form-<issue_id>`
  - Scoped “close open inline forms” selectors to Logged-tab forms only:
    - changed `.tep-inline-form` selector to `[id^="tep-inline-form-"]` in both inline toggle functions.
  - Ensured Unlogged inline form is explicitly unhidden when opened:
    - `issue-inline-form-<issue_id>` now removes `hidden` during toggle open.
  - Reworked Unlogged inline form markup to follow the same Logged-tab pattern:
    - compact horizontal strip with matching field/button styles (`tep-field`, `tep-action-btn`)
    - Flowbite-style custom activity dropdown (button + popover list + hidden value)
    - matching cancel/save action styles and inline error styling
  - Added Unlogged activity dropdown logic in JS:
    - `toggleIssueActivityDropdown`, `closeIssueActivityDropdown`, `resetIssueActivityDropdown`, `selectIssueActivity`
    - updated `loadIssueActivities` to populate dropdown options in the same pattern as Logged tab
    - updated submit logic to read hidden activity id
- Updated compiled Tailwind output:
  - `assets/stylesheets/tailwind.output.css`

## Verification Notes
- Ran `ruby test/test_working_days.rb` successfully.
- Ran `npm run build` successfully.
- Confirmed changed files:
  - `app/views/time_entry_panel/index.html.erb`
  - `assets/stylesheets/tailwind.output.css`

## Next Steps
- Quick UI check in Redmine:
- Open **My Work Log → Unlogged**.
- Click `Log` on multiple issues and confirm inline form opens each time.
- Confirm Unlogged inline form visually matches Logged inline pattern (field sizing, dropdown style, buttons, error state).
- Validate switching between Logged and Unlogged tabs does not break form visibility.
