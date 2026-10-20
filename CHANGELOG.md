# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- CI on every push and pull request; the release workflow (signed, notarized DMG and Claude extension, MCP
  registry).
