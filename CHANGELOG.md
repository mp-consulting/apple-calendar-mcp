# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Remote access for claude.ai and the Claude apps.** `apple-calendar-mcp remote` serves MCP over HTTP (Streamable
  HTTP) with OAuth 2.1: client registration, PKCE, rotated refresh tokens, revocation. It answers under the path of
  its public address (`https://mcp.example.com/me/calendar`), discovery documents included, so several servers can
  share one host name behind one tunnel. Connections are approved on a sign-in page with a passcode, or with Allow
  in the menu bar app (over the bridge); each may be read-only, and deleting and changing shared events still ask.
- Settings › Remote access: turn it on, the address, port and interface, the passcode, the connector URL and the
  tunnel's path pattern, and the connected apps with Disconnect. The menu bar app runs and restarts the server.

## [0.3.0] - 2026-10-22

### Added

- **What Claude may do, per calendar**: Settings sets each calendar (and reminder list) to *Read and change*,
  *Read only* or *Hidden*. Nothing is added to, moved into, changed or deleted in a read-only one.
- **Batches**: `create_events` and `update_events` add or change many events in one call. Every item is checked
  before anything changes, events other people are invited to are approved together in one request, and one
  `undo_id` puts the whole call back (`delete_event` returns one too).
- **Reminders**: `list_reminders`, `create_reminder`, `update_reminder` (including ticking off) and
  `delete_reminders`, with undo, through the menu bar app once it has Reminders access (Settings tab › Reminders).
  The agenda lists reminders due.
- `find_free_time` keeps only times inside someone else's working hours (`other_time_zone`, `other_hours`), and
  `format: "text"` returns the slots as lines to paste in a message.
- `find_duplicates`: events entered twice, the copy to keep, and the copies that can go (`delete_ids`).
- `export_events`: `ids` for exactly those events, `busy_only` to share free/busy without details, and `invite` to
  write an invitation people can accept or decline; the new `calendar-invite-by-mail` skill attaches it to a draft
  with Apple Mail MCP.
- The panel shows **Join** next to a video call that is on or starts within 10 minutes.

## [0.2.1] - 2026-10-22

### Fixed

- Showing one occurrence of a repeating event in Calendar (the menu bar app's Today and Activity, `open_in_calendar`)
  opened the series' first occurrence. It now opens that occurrence.

## [0.2.0] - 2026-10-22

### Added

- `respond_to_invitation`: accept, decline or answer "maybe" to an invitation (with `dry_run` to check first).
  Calendar sends the answer to the organizer. The menu bar app asks first, as for other changes to shared events.

### Fixed

- Undoing the creation of an event other people are invited to now asks "Delete a shared event?" instead of "Change".
- The bridge reads large replies (long searches, statistics, exports) in linear time, and link detection in event
  notes no longer rebuilds its detector for every event.
- A server started before the app was installed or set up now recovers on the next call instead of needing a
  restart of the MCP client.
- Dry runs of `update_event`, `delete_event` and `respond_to_invitation` say exactly what the real call would do
  about approval (`asks_first`, or `would_refuse` when a policy forbids it).

### Changed

- Servers keep one connection to the app open between requests instead of connecting (and checking signatures)
  for each one.
- Subscribed resources are recomputed only when the calendar changed, the day turned, or 15 minutes passed.
- The menu bar app starts its bridge first, reads calendars and Claude's config files off the main thread, and
  follows calendar changes and the day turning instead of polling every 30 seconds.

## [0.1.3] - 2026-10-22

### Changed

- When another account on the Mac updates Apple Calendar MCP, the running copy offers to relaunch into the new
  version instead of offering the same update again.

### Fixed

- A server still running after the app was updated, moved or deleted explains that, and asks to restart the
  MCP client (quit and reopen Claude), instead of reporting that it could not read its code signature.

## [0.1.2] - 2026-10-21

### Fixed

- **"Restart Claude" no longer stays after a restart.** The app compared the date of the Claude app's config file
  with Claude's launch, but Claude saves its own preferences in that file while it runs, so the file nearly always
  looked newer and the button never went away. The app now records when it changed its own entry and asks for a
  restart only when that change is newer than Claude's launch.

## [0.1.1] - 2026-10-21

### Fixed

- **Updates work when another account installed the app.** On a Mac with several accounts, the app in Applications
  belongs to whoever installed or last updated it, and the other accounts could not replace it: the update was
  offered, then failed at the last step. The updater now checks every folder in the app, and when this account
  cannot replace it, asks for an administrator's password and swaps it in as root, after checking the signature
  again on a copy only root can change. Every install also leaves the app writable by the `admin` group, so the
  next update needs no password from any administrator account.

  This version is installed by the previous updater, so an account that cannot write the app still has to install
  0.1.1 once from the release page (or run the update from the account that owns it).

## [0.1.0] - 2026-10-21

The first release.

### Added

- **Calendar store** (`CalendarStore`): events, calendars, attendees, alarms and repeat rules; EventKit reads and
  writes (one occurrence or the whole series); `MemoryBackend`, an in-memory calendar with EventKit's rules for
  tests and screenshots.
- **Bridge to the menu bar app**: servers use the app's Calendars permission over a Unix socket in the owner-only
  support folder. Each end checks the other's code signature (same team, this project's identifiers); approvals
  travel the same way.
- Free time within working hours with buffers, conflicts, time statistics (per calendar, weekday, hour and person,
  meeting load, back-to-back meetings), video links in events, and text matching.
- iCalendar files: reads invitations and exports (time zones, Outlook zone names, all-day events, repeat rules,
  alarms) and writes events.
- **MCP tools**: `agenda`, `list_events`, `search_events` (with `group_by`), `get_event`, `find_free_time`,
  `find_conflicts`, `pending_invitations`, `calendar_statistics`, `list_calendars`, `create_event`, `update_event`,
  `delete_event`, `undo_change`, `import_ics`, `export_events`, `open_in_calendar`; resources `calendar://today` and
  `calendar://upcoming`; the skills as prompts.
- **Policies**: deleting and changing events other people are invited to ask first in the menu bar app; calendars
  can be hidden from Claude; batch limit; read-only mode; undo journal.
- **Eight skills**: daily brief, scheduler, focus time, meeting prep, weekly review, time audit, cleanup, invite import.
- **Menu bar app** (Liquid Glass on macOS 26): holds the Calendars permission and hosts the bridge; approvals with a
  pager; today's events with now and next; activity; Claude setup and skills; settings (policies, working hours,
  visible calendars, the next event in the menu bar); daily update check.
- `apple-calendar-mcp --demo` and the app's `--demo --snapshot` (README screenshots) use a made-up week.
- CI on every push and pull request; the release workflow (signed, notarized DMG and Claude extension, MCP
  registry).

[Unreleased]: https://github.com/mp-consulting/apple-calendar-mcp/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/mp-consulting/apple-calendar-mcp/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mp-consulting/apple-calendar-mcp/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/mp-consulting/apple-calendar-mcp/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/mp-consulting/apple-calendar-mcp/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/mp-consulting/apple-calendar-mcp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mp-consulting/apple-calendar-mcp/releases/tag/v0.1.0
