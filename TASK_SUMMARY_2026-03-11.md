# Task Summary – My Work Log: Grouping + Inline Time Logging

**Date:** 2026-03-11

---

## 1. Overview

Updated the **My Work Log** page (`time_entry_panel`) with two major features:

1. **Grouping support** – A `Daily / Weekly / Monthly` dropdown (placed beside the time period buttons, matching the My Time page) that groups time log entries by the selected period. All dates/weeks/months in the selected range are shown even if they have no entries.

2. **Inline time logging** – Replaced the popup modal with in-page inline forms. Clicking `+ Log` on any group row (Time Logs tab) or issue row (Issues Worked On tab) reveals an inline form directly within the table—no modal required.

The popup modal HTML, all its JavaScript functions (`openLogTimeModal`, `closeLogTimeModal`, `submitLogTime`, `handleSubmitLogTime`, etc.) and all modal-specific CSS have been fully removed.

---

## 2. Code Changes

### `app/controllers/time_entry_panel_controller.rb`

- Added `before_action :set_grouping, only: [:index]`
- Added private `set_grouping` method (reads `params[:grouping]`, persists in `session[:tep_grouping]`, defaults to `'daily'`)
- Added private `build_grouped_entries(entries, grouping, from_date, to_date)` that:
  - Groups entries by daily / weekly / monthly period key (using Ruby `group_by`)
  - Fills in all periods in the date range (even empty ones)
  - Returns sorted array (most recent first) of `{ key:, entries:, total_hours:, entry_count: }`
- Replaced `@issues_with_logs` / `@time_entries_by_issue` with `@grouped_entries` and simplified `@issues_without_logs` derivation

### `app/views/time_entry_panel/index.html.erb`

- **Header filter bar**: Added grouping dropdown (`#tep-grouping-btn`) with `hidden_field_tag :grouping` alongside existing time period buttons
- **Time Logs tab**: Replaced per-issue expandable table with period-grouped rows:
  - Daily: date circle badge (blue = today), day name, entry count, total hours, `+ Log`
  - Weekly: "Week of Mar 1 - Mar 7, 2026" label
  - Monthly: "March 2026" label
  - Rows with entries auto-expand on page load
  - Expanded view: `Ticket | Issue | Project | Activity | Comment | Hours` table (+ `Date` column for weekly/monthly)
- **Inline form (Time Logs tab)**: Slides in above entries when `+ Log` is clicked:
  - Fields: Issue selector, Date (hidden for daily; date picker for weekly/monthly), Hours (`H:MM`), Activity (loaded via AJAX on issue select), Comment
  - Cancel / ✓ Save buttons
  - Validation with inline error message
- **Issues Worked On tab**: Each issue row has a `+ Log` button that expands an inline form with: Date, Hours, Activity (loaded via AJAX), Comment
- **Removed**: entire modal HTML block + all modal JS (`openLogTimeModal`, `closeLogTimeModal`, `submitLogTime`, `submitLogTimeAndAddAnother`, `handleSubmitLogTime`, `toggleActivityDropdown`, `showModalError`, `hideModalError`)
- **Added JS**: `toggleTepGroupingDropdown`, `setTepGroupingAndSubmit`, `toggleTepGroup`, `toggleTepInlineForm`, `hideTepInlineForm`, `loadTepActivities`, `submitTepInlineLog`, `toggleIssueInlineForm`, `hideIssueInlineForm`, `loadIssueActivities`, `submitIssueInlineLog`

### `assets/stylesheets/time_analytics.css`

- Removed `/* === Log Time Modal Styles === */` block (~150 lines) including `.modal-backdrop-overlay`, `#log-time-modal *`, `#activity-dropdown *`, `#modal-create-add-btn`
- Added `/* === Inline Time Log Form (My Work Log) === */` section with:
  - `.tep-inline-form` slide-down animation
  - `tep-grouping-wrapper` dropdown border overrides
  - Inline form `select` / `input` focus styles
  - `.rotate-90` utility for chevron animation

---

## 3. Verification Notes

- [ ] Daily grouping shows all 7 days (Last 7 Days), today highlighted in blue
- [ ] Weekly grouping shows full weeks, correct "Week of …" label
- [ ] Monthly grouping shows correct month labels
- [ ] Grouping dropdown persists via session between page reloads
- [ ] Clicking `+ Log` on a daily row opens inline form; date is fixed to that day
- [ ] Clicking `+ Log` on a weekly/monthly row opens inline form with date picker bounded to the period
- [ ] Selecting an issue in the inline form loads its activities via AJAX
- [ ] Saving a time entry reloads the page with updated data
- [ ] Issues Worked On tab inline form works for per-issue logging
- [ ] No popup modal appears anywhere
- [ ] Grouping dropdown is positioned beside the time period buttons

---

## 4. Next Steps

- Consider adding edit/delete actions for existing time entries inline (right now they are read-only)
- Add a "log time" summary badge count to the Time Logs tab showing total entries vs entries in period

---

## 5. Updates – 2026-03-12

### Merge Ticket + Issue columns → single Issue column

Both tables (Time Logs tab and Issues Worked On tab) previously had separate `Ticket` and `Issue` columns. These are now merged into a single **Issue** column that renders the combined format Redmine uses by default:

```
[Tracker #ID]  : Subject text
```

- The `[Tracker #ID]` part (e.g. `Task #13449`) is a blue pill badge and a link to the issue.
- The `: Subject text` part is a plain-text link that also navigates to the issue on click.
- High-priority issues still show the red warning icon to the left.

**Files changed:** `app/views/time_entry_panel/index.html.erb`
- Removed `<th>Ticket</th>` in both tables; merged into `<th>Issue</th>`
- Replaced the two separate `<td>` cells with a single combined cell per row
- Updated `colspan="6"` → `colspan="5"` on the Issues Worked On inline form row to match the new column count

### Remove Estimate column

The `Estimate` column (and `estimated_hours` variable) has been fully removed from the Time Logs tab.

- Removed `<th>Estimate</th>` header
- Removed `<% estimated = issue.estimated_hours %>` variable
- Removed the estimate `<td>` cell that rendered `—` or `98:00h`

---

## 6. Updates – 2026-03-12 (expandable entry rows)

### Feature: Click-to-expand individual time entries per issue

Each issue row in the **Time Logs tab** is now expandable. By default rows are collapsed. Clicking any row (or its chevron `›`) reveals a sub-table of the individual time entries logged against that issue in the period.

#### Sub-table columns
| Date | Activity | Comment | Hours | ✏️ Edit | 🗑 Delete |

- **Edit**: clicking the pencil icon toggles an inline edit form (Activity dropdown, Comment text input, Hours H:MM input). Save submits `PATCH /time_entry_panel/entry/:id`, Cancel reverts.
- **Delete**: clicking the trash icon shows a `confirm()` dialog, then submits a `DELETE /time_entry_panel/entry/:id` form. Both redirect back to the same page.

#### Files changed
**`config/routes.rb`**
- Added `PATCH time_entry_panel/entry/:id → #update_entry`
- Added `DELETE time_entry_panel/entry/:id → #destroy_entry`

**`app/controllers/time_entry_panel_controller.rb`**
- `build_grouped_entries`: added `entries: []` to `issue_map[key]`; each `TimeEntry` record is pushed into the array and sorted by `[spent_on, created_on]` in the final row merge
- Added `update_entry` action (validates ownership, updates hours/activity/comments, redirects back)
- Added `destroy_entry` action (validates ownership, destroys entry, redirects back)
- Added `parse_hours(value)` helper converting H:MM or decimal string → Float

**`app/views/time_entry_panel/index.html.erb`**
- `<thead>`: added empty chevron `<th class="w-8">` before Issue column
- `issue_rows.each` → `issue_rows.each_with_index` to build unique `entry_uid = "#{idx}-#{row_idx}"`
- Issue `<tr>`: added `onclick="tepToggleIssueEntries(uid)"`, cursor-pointer; chevron `<td>` with rotating SVG
- New hidden `<tr id="tep-issue-expand-…">` after each issue row with entries sub-table + display/edit rows
- JS: `tepToggleIssueEntries`, `tepToggleEditEntry`, `tepDeleteEntry` functions

**`assets/stylesheets/time_analytics.css`**
- Added `.tep-entry-edit-form` styles for input/select focus states
