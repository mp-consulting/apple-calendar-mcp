---
name: calendar-focus-time
description: Protect focus time in Apple Calendar. Use when the user wants deep-work blocks, time to think or write, no-meeting time, to "block my calendar", or to plan their week around priorities. Finds the gaps, proposes blocks of useful length, and adds them as busy events after the user agrees.
---

# Focus time

## Steps

1. **Ask for the shape**, with defaults: how many hours this week (default 6), block length (default 90
   minutes, never under 45), preferred time of day (default mornings), and what the blocks are for (the
   title: "Focus: <topic>").
2. **See the week.** Call `find_free_time` for the range (default: from now to the end of the work week) with
   `duration_minutes` set to the block length, `buffer_minutes: 10`, and `earliest`/`latest` for the
   preferred time of day. Call `calendar_statistics` for the same range to see how much is already meetings.
3. **Plan the blocks**: spread them over different days, at most one or two per day, never splitting a free
   stretch into pieces too short to use. Leave lunch free (12:00–13:30 unless the user's day says otherwise).
4. **Show the plan** as a list (day, start–end, title) and the hours it adds up to. Wait for a yes, or adjust.
5. **Add** all the blocks in one `create_events` call (`events`, each with `availability: "busy"`,
   `alarms: [5]`, the agreed title, and `notes` with what to work on if the user said). For a weekly habit use
   one `create_event` with `repeat` (`frequency: "weekly"`, `weekdays`) instead of separate events.
6. Report what was added. The `undo_id` it returns removes all of them with `undo_change`.

## Rules

- Add nothing before the user approves the plan.
- Do not move other people's meetings to make room; suggest it and let the user decide.
- Respect existing focus blocks (search them with `search_events`, `query: "focus"`) instead of adding more.

<!-- Installed by Apple Calendar MCP (https://github.com/mp-consulting/apple-calendar-mcp). -->
