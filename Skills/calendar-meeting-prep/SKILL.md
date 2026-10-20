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
