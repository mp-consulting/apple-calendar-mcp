# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/mp-consulting/apple-calendar-mcp/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/mp-consulting/apple-calendar-mcp/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/mp-consulting/apple-calendar-mcp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mp-consulting/apple-calendar-mcp/releases/tag/v0.1.0
