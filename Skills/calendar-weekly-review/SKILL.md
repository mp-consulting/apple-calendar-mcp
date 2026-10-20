---
name: calendar-weekly-review
description: Weekly calendar review from Apple Calendar. Use when the user asks how their week went, for a weekly recap or planning session, what next week looks like, or how busy they are. Compares last week's time with next week's load, lists what needs preparation, and proposes changes.
---

# Weekly review

## Steps

1. **Last week.** `calendar_statistics` from last Monday to this Monday: hours in meetings versus the rest, the
   busiest days, back-to-back meetings, the people the user met most, the calendars time went to.
2. **Next week.** `calendar_statistics` and `find_conflicts` for the coming Monday to Sunday, then
   `pending_invitations` for the same range, and `find_free_time` (`duration_minutes: 90`) to see how much
   uninterrupted time is left.
3. **What stands out**: days over 6 hours of meetings, days without a 90-minute gap, conflicts, invitations
   not answered, recurring meetings that take a lot of time (`search_events` with `recurring: true` and
   `group_by: "calendar"`), deadlines or travel in all-day events.
4. **Report** in this order, briefly:
   - last week in three numbers (meeting hours, focus hours, events) and one sentence on what it was about;
   - next week, day by day: load and the main event of each day;
   - **to do**: conflicts to resolve, invitations to answer, meetings to prepare;
   - **suggestions**: focus blocks to add, meetings to shorten or decline, days to protect.
5. Offer the follow-ups: add focus time (the `calendar-focus-time` skill), fix conflicts
   (`update_event`), prepare meetings (the `calendar-meeting-prep` skill).

## Rules

- Hours are rounded to the half hour; percentages to whole numbers.
- Declined, cancelled and free events are not counted as busy.
- Change nothing unless the user asks.

<!-- Installed by Apple Calendar MCP (https://github.com/mp-consulting/apple-calendar-mcp). -->
