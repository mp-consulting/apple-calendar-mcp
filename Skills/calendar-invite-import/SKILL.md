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
