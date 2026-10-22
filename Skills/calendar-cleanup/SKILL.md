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
