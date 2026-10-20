<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Apple Calendar MCP icon">
</p>

<h1 align="center">Apple Calendar MCP</h1>

<p align="center">
  Let Claude read, search and plan your Apple Calendar: fast, local, and nothing deleted or sent to other people without your OK.
</p>

<p align="center">
  <a href="https://github.com/mp-consulting/apple-calendar-mcp/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/mp-consulting/apple-calendar-mcp?include_prereleases"></a>
  <a href="https://github.com/mp-consulting/apple-calendar-mcp/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mp-consulting/apple-calendar-mcp/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 14+, Apple silicon and Intel" src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20universal-blue">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

> **Status: in development, not released yet.** The server, its tools and skills, and the menu bar app work; the
> first signed release (DMG, Claude extension, Homebrew) is next. See [CHANGELOG.md](CHANGELOG.md).

Apple Calendar MCP is an [MCP](https://modelcontextprotocol.io) server for the Calendar app on your Mac, plus a
small menu bar app. Claude (Claude Code, the Claude app, or any MCP client) can see your day, search years of
events, find free time across all your calendars, plan focus blocks, prepare meetings, and add or move events,
and it can only delete an event, or change one other people are invited to, after you click **OK**.

The companion of [Apple Mail MCP](https://github.com/mp-consulting/apple-mail-mcp), built the same way.

<p align="center">
  <picture><source media="(prefers-color-scheme: light)" srcset="docs/images/tab-calendar-light.png"><img src="docs/images/tab-calendar.png" width="300" alt="Calendar tab: a shared event change waiting for approval, two more requests below, today's events with what is on now and next, recent activity"></picture>
  <picture><source media="(prefers-color-scheme: light)" srcset="docs/images/tab-claude-light.png"><img src="docs/images/tab-claude.png" width="300" alt="Claude tab: Claude Code and the Claude app, the eight skills by slash command"></picture>
  <picture><source media="(prefers-color-scheme: light)" srcset="docs/images/tab-settings-light.png"><img src="docs/images/tab-settings.png" width="300" alt="Settings tab: delete and shared-event policies, working hours, which calendars Claude can see"></picture>
</p>

## Any calendar account, ready for AI

Apple Calendar MCP works with **every calendar you can add to Calendar**: iCloud, Google, Microsoft 365 and
Exchange, Yahoo, Fastmail, any CalDAV server, subscribed calendars (holidays, sports, team schedules), birthdays,
and calendars on your Mac only.

Your provider needs no API, no developer account and no MCP support of its own. Add the account in Calendar ›
Settings › Accounts as you normally would; as soon as Calendar syncs it, every tool works with it, side by side
with the others. Your passwords stay with macOS: this app never sees them and never connects to your provider.

## Why another Calendar server?

Most Calendar servers drive Calendar with AppleScript. Calendar then walks its events one by one, so a search over
a busy year takes seconds or times out, repeating events come back wrong, and Calendar is busy meanwhile.

Apple Calendar MCP uses **EventKit**, the framework Calendar itself is built on. Reads are database queries that
return in milliseconds, repeating events expand exactly as Calendar shows them, and Calendar never has to run.

- **Fast**: a day, a week or a year of events in milliseconds, from every account at once.
- **Free time that knows your week**: working hours, buffers between meetings, all-day and declined events
  handled the way Calendar shows them.
- **Safe by default**: deleting asks first, changes to events other people are invited to ask first, every change
  can be undone, and calendars you hide are never shown to Claude.
- **One permission**: Calendars, given once to the menu bar app. No Full Disk Access, no Automation.
- **No passwords, no cloud**: everything stays on your Mac.

## Install

The first release will come as a notarized, Developer ID signed **DMG** (the menu bar app with the server inside),
a **Claude extension** (`.mcpb`), and a Homebrew cask (`mp-consulting/tap/apple-calendar-mcp`), like Apple Mail
MCP. Until then, build it from source (see [Development](#development)).

Then:

1. Open **Apple Calendar MCP**: a calendar appears in the menu bar.
2. Click **Allow Calendar Access** and choose **Allow Full Access** in the macOS prompt.
3. Open the **Claude** tab and click **Connect** next to Claude Code and/or the Claude app.

### Permissions

macOS gives calendar access to the app that starts a process. Claude, a terminal or an editor starts the server,
and none of them can be given Calendar access on its behalf. So the **menu bar app holds the Calendars
permission**, and servers reach your calendars through it, over a socket in your owner-only support folder. Each
side checks the other's code signature: the app answers only this project's server, and the server talks only to
this project's app. If the app is not running, the server opens it in the background.

| Permission | Why | Where |
|---|---|---|
| **Calendars › Full Access** for Apple Calendar MCP | Read and change events | Asked once by the app; System Settings › Privacy & Security › Calendars |

## What Claude can do

| Tool | What it does |
|---|---|
| `agenda` | Today (or the next days) in one call: what's now and next, conflicts, free time left, open invitations |
| `list_events` | Events in a period, from all calendars or some, repeating ones expanded |
| `search_events` | Text, person, place, calendar, dates, video calls, status; or counts per calendar, month, weekday or person with `group_by` |
| `get_event` | One event in full: notes, attendees and their answers, alarms, repeat rule, video link |
| `find_free_time` | Slots of a given length within your working hours, with buffers, across every calendar that counts |
| `find_conflicts` | Overlapping events that both take the time |
| `pending_invitations` | Invitations you haven't answered |
| `calendar_statistics` | Where time went: per calendar, weekday, hour and person, meeting load, back-to-back meetings |
| `list_calendars` | Calendars with their account, colour and whether they can be changed |
| `create_event`, `update_event`, `delete_event` | Add, change, move or delete events, one occurrence or the whole series, with alarms and repeat rules |
| `undo_change` | Lists recent changes and puts one back |
| `import_ics`, `export_events` | Add events from an `.ics` file (an invitation saved from Mail), or write events to `.ics`, CSV or JSON |
| `open_in_calendar` | Show an event or a day in Calendar |

Event ids are EventKit's own; one occurrence of a repeating event is `<id>#<start in Unix seconds>`.

EventKit cannot invite people or answer invitations. Attendees and their answers are shown, and invitations are
answered in Calendar.

## You stay in control

<p align="center">
  <picture><source media="(prefers-color-scheme: light)" srcset="docs/images/approval-light.png"><img src="docs/images/approval.png" width="460" alt="The approval window: a change to a shared event shown in full with a 1 of 3 pager and the people who may be told, two deletions waiting below"></picture>
</p>

When Claude wants to delete events, or change an event other people are invited to, a small window pops up with
what would change; nothing happens without a click on **OK**.

- **Delete policy** (Settings): *Ask me first* (the default), *Delete right away*, or *Never delete*.
- **Shared events**: changes to events with other attendees ask first by default, because their calendar server
  may tell them.
- **Undo**: every change can be put back with `undo_change`. A deleted event comes back without its attendees
  (EventKit cannot invite them again).
- **Hidden calendars**: calendars you hide in Settings are never read, listed or changed.
- **Batch limits**: at most 50 events per change by default.
- **Read-only mode**: `apple-calendar-mcp --read-only` offers only the reading tools.
- **Activity**: every tool call is listed in the menu bar app (never with event details).

## Skills

Pick them in the panel's **Claude** tab: each one shows what it does and whether it's installed.

| Skill | Or just ask… |
|---|---|
| `/calendar-daily-brief` | "What does my day look like?" |
| `/calendar-scheduler` | "Find an hour with no meetings next week for the budget review." |
| `/calendar-focus-time` | "Block six hours of focus time this week, mornings if possible." |
| `/calendar-meeting-prep` | "Prepare me for my meetings tomorrow." |
| `/calendar-weekly-review` | "How did my week go, and what does next week look like?" |
| `/calendar-time-audit` | "Where did my time go this month?" |
| `/calendar-cleanup` | "Find duplicates and conflicts in my calendar and clean them up." |
| `/calendar-invite-import` | "Add this flight confirmation to my calendar." |

The skills are also served as MCP prompts (in Claude Code: `/mcp__apple-calendar__calendar-daily-brief` and so
on), and two resources, `calendar://today` and `calendar://upcoming`, notify subscribed clients when the day changes.

## Command line

```text
apple-calendar-mcp [--read-only]                                        serve MCP over stdio
apple-calendar-mcp doctor                                               check the app, the permission and the bridge
apple-calendar-mcp install | uninstall [claude-code | claude-desktop]   register with Claude
apple-calendar-mcp skills [list | install | uninstall | export DIR]     manage the Claude skills
apple-calendar-mcp call <tool> '{"json": "arguments"}'                  run one tool
```

## How it works

```text
Claude ──MCP (stdio)──▶ apple-calendar-mcp ──socket (signatures checked)──▶ Apple Calendar MCP.app ──▶ EventKit ──▶ your accounts
                                                                            menu bar: approvals · activity · settings · Claude setup · updates
```

- **CalendarStore**: the event model, EventKit, the bridge, repeat rules, free time, conflicts, statistics and
  iCalendar files.
- **CalendarMCPKit**: the tools, policies, approvals, undo and skills; **CalendarMCPBar** is the SwiftUI menu bar
  app (Liquid Glass on macOS 26).

## Development

```sh
git clone https://github.com/mp-consulting/apple-calendar-mcp && cd apple-calendar-mcp
# Files under ~/Documents carry Finder metadata that codesign rejects: build outside the repo.
swift test --scratch-path ~/Library/Caches/apple-calendar-mcp-build   # tests run on in-memory calendars
Scripts/build-app.sh --install                                        # build, sign, install, launch the app
```

`apple-calendar-mcp --demo` serves a made-up week from memory, to try the tools without touching your calendars.
The screenshots come from the app's `--demo --approval 3 --snapshot DIR`.

Tests never touch your calendars: they run on `MemoryBackend`, which follows EventKit's rules for repeating
events and read-only calendars. Requires Xcode 26 (Swift 6.2) for the app; the server builds with Swift 6.1.

## License

[MIT](LICENSE) © 2026 Mickael Palma. Not affiliated with Apple. Apple Calendar is a trademark of Apple Inc.
