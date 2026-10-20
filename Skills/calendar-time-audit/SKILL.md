---
name: calendar-time-audit
description: Audit where time goes in Apple Calendar over weeks or months. Use when the user asks where their time goes, how many hours they spend in meetings, with whom, which meetings to cut, or wants a time report for a period or a project. Builds a report from calendar statistics with trends and concrete suggestions.
---

# Time audit

## Steps

1. **Period and scope.** Default: the last 4 full weeks. Ask whether to include all calendars or only some
   (`list_calendars`); hidden calendars are never visible to Claude.
2. **The numbers.** `calendar_statistics` for the whole period, then for each week (to see the trend). Note
   total and meeting hours, the share of recurring events, back-to-back meetings, hours per weekday and per
   hour of the day, the top people and calendars.
3. **The big items.** `search_events` with `recurring: true` and `group_by: "calendar"` to find the standing
   meetings, and `get_event` on the largest ones to see how long, how often and with how many people.
   For a project or client, `search_events` with `query` (its name) or `person` and `group_by: "month"`.
4. **Report**:
   - a summary table: week, meeting hours, other events, longest free block;
   - where time went: by calendar, by person (top 5), by kind (one-on-ones, team meetings, external);
   - patterns: meeting-heavy days, hours rarely free, back-to-back streaks;
   - **three suggestions**, each with its saving in hours per week (shorten a recurring meeting to 25 or 50
     minutes, move one-on-ones to the same afternoon, protect a focus morning).
5. Offer to export the period with `export_events` (`format: "csv"`) for a spreadsheet.

## Rules

- Change nothing; the audit only reads.
- People's names are fine in the report; do not quote event notes.

<!-- Installed by Apple Calendar MCP (https://github.com/mp-consulting/apple-calendar-mcp). -->
