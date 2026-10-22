---
name: calendar-scheduler
description: Find a time and put it in Apple Calendar. Use when the user asks to schedule, book, plan, find a slot or time for something, move a meeting, or "when am I free". Searches free time with the user's working hours and buffers, proposes a few options, and creates or moves the event only after the user picks one.
---

# Scheduler

## Understand the request

Pin down, asking only for what is missing and cannot be guessed:
- **how long** (default 30 minutes for a call, 60 for a meeting),
- **when**: a day, a range ("next week"), or "as soon as possible" (the next five working days),
- **constraints**: mornings only, not back-to-back, before a deadline, a place to travel to,
- **which calendar** for the new event (default: the user's default calendar, see `list_calendars`).

## Find options

1. Call `find_free_time` with `start`, `end`, `duration_minutes`, and `buffer_minutes` (10 by default, 30 if
   travel is involved). Leave `work_hours_only` on unless the user wants evenings or weekends. Use
   `earliest` and `latest` (`HH:MM`) for "mornings only" and the like.
   When the other person is in another time zone, pass `other_time_zone` (and `other_hours` if their day is
   not 09:00–18:00): only times inside both working days remain. For options to paste in a message, pass
   `format: "text"` and use its `text`.
2. If nothing fits, widen once (a longer range, or outside working hours) and say what you relaxed.
3. Prefer slots that keep the day in one piece: next to existing meetings rather than in the middle of a
   long free block, unless the user wants a long block (then the reverse).
4. Propose **two or three** options: day, start–end, and why each is good ("right after your 10:00, keeps
   the afternoon free").

## Book

1. When the user picks one, call `create_event` with `title`, `start`, `end` (or `duration_minutes`), and
   `calendar`, `location`, `notes`, `url` and `alarms` when known. Use `dry_run: true` first if the user
   wants to see it before it is added.
2. To move an existing event instead, find it (`search_events`), then `update_event` with its `id` and the
   new `start` (the length is kept unless `end` is given). For one occurrence of a repeating event use its
   occurrence id and `span: "this"`; for it and everything after, `span: "future"`.
3. Confirm what was done with the event's time and calendar. `undo_change` reverses it.

## Rules

- Never create or move anything before the user chose an option.
- EventKit cannot invite people: create the event for the user only, and tell them to invite others from
  Calendar (`open_in_calendar` with the new id), or send the invitation by email (the
  `calendar-invite-by-mail` skill).
- Several events at once (a series of sessions, a trip): `create_events`; moving several: `update_events`.
- Changing an event other people are invited to may notify them; the app asks the user first. Mention it.
- Use the user's time zone unless they name another; then pass `time_zone`.

<!-- Installed by Apple Calendar MCP (https://github.com/mp-consulting/apple-calendar-mcp). -->
