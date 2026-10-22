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
