---
name: calendar-daily-brief
description: Daily Apple Calendar briefing. Use when the user asks what their day or tomorrow looks like, what's next, whether they have time today, or for a morning calendar review. Lists the day in order, flags conflicts and invitations, shows free time, and says what to prepare.
---

# Daily brief

Give the user their day in under a minute of reading. Uses the Apple Calendar MCP server (`apple-calendar`):
reads come from EventKit through the menu bar app and never change anything.

## Steps

1. **The day.** Call `agenda` (`days: 1`; for "tomorrow" pass `date` as tomorrow's `YYYY-MM-DD`). It returns
   the events in order, what is happening now and next, conflicts, free time left in working hours, and
   invitations still waiting for an answer.
2. **Look closer only where it matters.** For a meeting with an unclear purpose, many attendees or a long
   description, call `get_event` (`notes_limit: 800`) to read its notes, attendees and video link.
3. **Present**, in this order and briefly:
   - one line: how many events, how much is meeting time, the first start and the last end;
   - the timeline: time, title, where (room or video), and a short note when something needs doing first
     (a document to read, a decision to make, travel time);
   - **conflicts** (`conflicts`): the two events and how long they overlap;
   - **free time** (`free`): the longest gaps, rounded to the quarter hour;
   - **invitations to answer** (`pending_invitations`): title, organizer, when.
4. **Offer actions**, then wait for the user to choose:
   - move or shorten an event (`update_event`), block focus time in a gap (the `calendar-focus-time` skill),
   - prepare a meeting (the `calendar-meeting-prep` skill),
   - answer an invitation (`respond_to_invitation`: accepted, declined or tentative),
   - open something in Calendar (`open_in_calendar`).

## Rules

- Change nothing during the brief. Every change waits for the user's yes.
- Answering an invitation sends the answer to the organizer: do it only when the user says which answer. If
  `respond_to_invitation` says Calendar does not allow it, offer `open_in_calendar`.
- All-day events (holidays, birthdays, travel) go on one line at the top, not in the timeline.
- Times are the user's local time; mention a meeting's own time zone only when it differs.
- If `agenda` reports that calendar access is missing or the app is not running, tell the user to open
  Apple Calendar MCP and allow Calendar access, then stop.

<!-- Installed by Apple Calendar MCP (https://github.com/mp-consulting/apple-calendar-mcp). -->
