// Generated from Skills/*/SKILL.md by Scripts/embed-skills.sh. Do not edit by hand.

extension SkillCatalog {
    static let embedded: [(folder: String, content: String)] = [
        ("calendar-cleanup", #"""
---
name: calendar-cleanup
description: Clean up Apple Calendar safely. Use when the user wants to fix conflicts, remove duplicates, clear out old or test events, tidy a calendar, or delete events matching something. Finds the candidates, previews every change, and deletes or moves only what the user confirms, in small batches.
---

# Calendar cleanup

## Find what to fix

- **Conflicts**: `find_conflicts` for the next 4 weeks. For each pair, suggest which to move and where
  (`find_free_time`), without moving anything yet.
- **Duplicates**: `find_duplicates` for the period. Each group names the copy to keep and the copies to
  remove; `delete_ids` holds those that can go safely (a copy in a read-only calendar, or a meeting others are
  invited to, is never in it). A repeating duplicate is reported once: delete it with `span: "future"`.
- **Matching events**: `search_events` with `query`, `calendar`, `start` and `end` for what the user
  describes ("all the test events", "the old team standup").
- **Stale series**: `search_events` with `recurring: true` over the coming months; repeating meetings whose
  organizer left, or that nobody accepted, are candidates to end (`span: "future"`).

## Preview, then act

1. Show the candidates as a table: when, title, calendar, why. Ask the user to confirm the list.
2. Preview the change with `delete_event` (`ids`, `dry_run: true`), or `update_event` with `dry_run: true`.
3. Delete in batches of at most 20 (`delete_event` takes several `ids`); move several events at once with
   `update_events` (`changes`). Each call asks for the user's OK once in the Apple Calendar MCP app; tell the
   user to look for it.
4. Report what was done and remind the user that the call's `undo_id` puts the whole batch back with
   `undo_change` (a deleted event comes back without its attendees).

## Rules

- Never delete without the user confirming the exact list.
- Read-only calendars (subscriptions, holidays, birthdays) cannot be changed; leave them out.
- For a repeating event, say whether one occurrence (`span: "this"`) or the series from there on
  (`span: "future"`) goes.
- Events other people are invited to: deleting may notify them. Prefer declining in Calendar for meetings the
  user did not organize.

<!-- Installed by Apple Calendar MCP (https://github.com/mp-consulting/apple-calendar-mcp). -->

"""#),
        ("calendar-daily-brief", #"""
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
   - **invitations to answer** (`pending_invitations`): title, organizer, when;
   - **reminders due** (`reminders_due`, when the user gave Reminders access): overdue ones first.
4. **Offer actions**, then wait for the user to choose:
   - move or shorten an event (`update_event`), block focus time in a gap (the `calendar-focus-time` skill),
   - prepare a meeting (the `calendar-meeting-prep` skill),
   - answer an invitation (`respond_to_invitation`: accepted, declined or tentative),
   - tick off a reminder (`update_reminder` with `completed: true`) or add one (`create_reminder`),
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

"""#),
        ("calendar-focus-time", #"""
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

"""#),
        ("calendar-invite-by-mail", #"""
---
name: calendar-invite-by-mail
description: Invite people to an Apple Calendar event by email. Use when the user wants to invite someone, send an invitation, share a meeting or event with others, or "send them the calendar invite". Calendar's EventKit cannot invite attendees, so this writes a standard .ics invitation and attaches it to an email draft (with Apple Mail MCP when it is connected), which the user sends.
---

# Invite by email

EventKit (what Apple Calendar MCP uses) cannot add attendees to an event. An email with an `.ics` invitation
works with every calendar: the people invited see Accept and Decline, and their answers come back to the user
by email. The event stays in the user's calendar without the attendees listed.

## Steps

1. **The event.** Find it (`search_events`, or `agenda`), or create it first (the `calendar-scheduler` skill).
   For a time that suits people in other time zones, use `find_free_time` with `other_time_zone`.
2. **Who and from whom.** Ask for the email addresses to invite, and the user's own address (the organizer,
   where the answers go) unless you know it.
3. **Write the invitation.** `export_events` with `ids` (the event's id), a `path` ending in `.ics` in a
   folder the user can find (Downloads by default), and `invite` with `organizer`, `organizer_name` and
   `attendees`. It returns the path.
4. **The email.** If Apple Mail MCP is connected, call its `compose_email` with the attendees in `to`, a short
   subject ("Invitation: <title>, <day> <time>"), a two-line body (what, when, where or the video link), and
   the `.ics` path in `attachments`. Leave it as a draft and tell the user to review and send it. Without Apple
   Mail MCP, give the path and the text so the user can attach it themselves.
5. **Answers** come back as emails ("Accepted: …"). With Apple Mail MCP, `search_messages` for the title finds
   them later.

## Rules

- Never send the email yourself: save a draft, and the user sends it.
- Invite only the addresses the user gave.
- Changing the event later does not update the people invited: send them a new invitation (the same steps,
  so the same event updates in their calendars).
- For a meeting someone else organized, do not send invitations: answer it with `respond_to_invitation`.

<!-- Installed by Apple Calendar MCP (https://github.com/mp-consulting/apple-calendar-mcp). -->

"""#),
        ("calendar-invite-import", #"""
---
name: calendar-invite-import
description: Add events to Apple Calendar from invitation files and booking confirmations. Use when the user has an .ics file, a calendar invitation attachment, or a confirmation (flight, train, hotel, restaurant, appointment, concert) and wants it in their calendar. Reads the details, checks for clashes, and adds the events after the user confirms.
---

# Invite import

## From an .ics file

1. Get the file's path. If it is a mail attachment and a mail server (such as Apple Mail MCP) is connected,
   save the attachment to a folder first and use that path.
2. Preview with `import_ics` (`path`, `dry_run: true`): it lists each event with its time, place and repeat
   rule, and says whether the file is an invitation.
3. Check the times against the calendar: `find_conflicts` (or `list_events`) around each event.
4. Show the user what will be added, in which `calendar`, and any clash. Then call `import_ics` again
   without `dry_run`.

## From a confirmation in words

1. Read the details the user pasted (or the message they point to): what, date, start and end, time zone,
   address, booking reference, and for travel the departure and arrival places.
2. Create the event with `create_event`: a clear title ("Flight AF1234 Paris → Lisbon", "Dinner at Taberna"),
   `start` and `end` in the place's `time_zone`, `location`, the reference and useful details in `notes`,
   and `alarms` (a day before for travel, an hour before otherwise). Hotel stays are `all_day` from check-in
   to check-out with `availability: "free"`.
3. Show it first with `dry_run: true` when anything was guessed.

## Rules

- Importing an invitation adds a copy to the user's calendar; it does not answer the organizer. To accept or
  decline, the user opens the invitation in Calendar or Mail.
- Never add events the user did not ask for; ask before adding several.
- Keep times in the time zone of the place (a flight leaves in local time), and say so.

<!-- Installed by Apple Calendar MCP (https://github.com/mp-consulting/apple-calendar-mcp). -->

"""#),
        ("calendar-meeting-prep", #"""
---
name: calendar-meeting-prep
description: Prepare upcoming meetings from Apple Calendar. Use when the user asks to prepare for a meeting, what a meeting is about, who is coming, what they need before their next call, or for a briefing on today's or tomorrow's meetings. Summarizes purpose, people, links, history and open questions for each meeting.
---

# Meeting prep

## Steps

1. **Which meetings.** The one the user names (find it with `search_events`, `query` and a date range), or the
   next meetings with other people: `list_events` for the rest of today (or tomorrow), keeping events with
   attendees.
2. **Read each one** with `get_event` (`notes_limit: 2000`): purpose from the title and notes, organizer,
   attendees and their answers, the video link or room, attachments mentioned in the notes.
3. **History with these people.** `search_events` with `person` set to the main attendee (or organizer) over
   the past 90 days (`start` 90 days ago, `end` now): when they last met and what those meetings were.
   For a repeating meeting, the previous occurrence's notes often hold the last agenda.
4. **Other context.** If a mail server (such as Apple Mail MCP) is also connected, look there for recent
   messages with the attendees about the topic, and mention what is unresolved.
5. **Brief**, one block per meeting:
   - **When / where**: time, length, video link or room, and travel time if it is somewhere else;
   - **Why**: the purpose in one sentence;
   - **Who**: attendees with their answer (accepted, tentative, no answer yet), the organizer first;
   - **Before**: what to read, decide or bring;
   - **Last time**: the previous meeting with them, if any.
6. Offer to add prep time before a meeting (`create_event`, 15–30 minutes, right before it, if free).

## Rules

- Quote as little of the notes as possible; summarize. The user can open the event with `open_in_calendar`.
- Do not change the meeting itself. Changes to events with other attendees may notify them.

<!-- Installed by Apple Calendar MCP (https://github.com/mp-consulting/apple-calendar-mcp). -->

"""#),
        ("calendar-scheduler", #"""
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

"""#),
        ("calendar-time-audit", #"""
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

"""#),
        ("calendar-weekly-review", #"""
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

"""#),
    ]
}
