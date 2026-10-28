# Apple Calendar MCP

An MCP server for Apple Calendar in Swift, plus a menu bar app. The companion of Apple Mail MCP
(`../apple-mail-mcp`), built the same way: same scripts, release workflow, updater, installer and panel layout.

## Layout

| Target | What it is |
|---|---|
| `CalendarStore` | Models, `CalendarBackend` (EventKit, memory, bridge), repeat rules, free time, conflicts, statistics, iCalendar |
| `CalendarMCPKit` | MCP tools (`Tools+*.swift`), settings and policies, undo journal, activity log, path guard, skills, installer, doctor; `Remote/`: the HTTP server for claude.ai, as Apple Mail MCP's (`HTTPListener`, `RemoteServer` under the public address's path, `RemoteAccess` OAuth in `remote-access.json`, `AuthorizePage`; connect approvals over the bridge); docs/remote.md |
| `apple-calendar-mcp` | The server and CLI (`serve`, `remote`, `doctor`, `install`, `skills`, `call`, `--demo`) |
| `CalendarMCPBar` | The menu bar app (SwiftUI, as Apple Mail MCP's): bridge host, approvals, today, activity, Claude setup, settings, updater; `RemoteHost` runs `apple-calendar-mcp remote` while remote access is on |
| `CalendarFixtures` | The made-up demo week (tests, `--demo`, screenshots) |
| `Skills/` | The Claude skills, one `SKILL.md` each; embedded into the binary |

## Commands

```sh
# Files under ~/Documents carry Finder metadata that codesign rejects: build outside the repo.
swift build --scratch-path ~/Library/Caches/apple-calendar-mcp-build
swift test  --scratch-path ~/Library/Caches/apple-calendar-mcp-build

Scripts/build-app.sh             # signed "Apple Calendar MCP.app" in ~/Library/Caches/AppleCalendarMCP/dist
Scripts/build-app.sh --install   # also copies it to ~/Applications and relaunches it
Scripts/embed-skills.sh          # after editing Skills/*/SKILL.md (a test fails if you forget)
swift Scripts/make-icon.swift Resources --png /tmp/icon.png

# Screenshots for the README (demo week, never real calendars):
APPLE_CALENDAR_MCP_SUPPORT_DIR=/tmp/acm-demo "…/Apple Calendar MCP.app/Contents/MacOS/Apple Calendar MCP" --demo --approval 3 --snapshot docs/images
```

## Rules

- **Never touch real calendars in tests.** Tests run on `MemoryBackend` / `StandardFixture`. Logs and activity
  never hold event titles or notes (the undo journal does, owner-only, because undo needs them).
- **The permission lives in the app.** macOS gives Calendars access to the responsible app; MCP clients (Claude,
  terminals, editors) cannot be given it for our server. The menu bar app holds it and serves EventKit over
  `bridge.sock` in the owner-only support folder. Both ends check the other's code signature
  (`PeerRequirement.matchingSelf`: same team, or the same local certificate, and one of our identifiers), so the
  socket never becomes a way around the permission. Do not add a "trust any process" switch outside tests, and do
  not use private APIs (responsibility disclaim) to get the permission into the server.
- A server with Calendars access of its own (a terminal that has it) uses EventKit directly; approvals still go
  through the app.
- Approvals travel over the bridge (no files, no Keychain key): deleting and changing events with other attendees
  ask first by default (`deletePolicy`, `sharedEventPolicy`).
- EventKit cannot invite attendees. Say so in tools and skills; offer `open_in_calendar`, or an emailed invitation
  (`export_events` with `invite`, the `calendar-invite-by-mail` skill).
- Reminders share the EventKit store but have their own permission, asked only from the app's Settings tab; every
  reminder tool says so when it is missing. Reminder lists use the same hidden/read-only settings as calendars.
- Calls that change several items record one `group` in the undo journal; `undo_change` takes the group id and
  asks once.
- Answering invitations (`respond_to_invitation`) uses Calendar's undocumented `-[EKEvent setParticipationStatus:]`,
  each call behind `responds(to:)`; when it is missing the tool says so and offers `open_in_calendar`. This is the
  one private API we use, in the app only (the server never touches EventKit's private side).
- Tool output is compact JSON (`JSON.obj`, keys in a deliberate order, false/empty fields omitted).
- Skills may only mention tools and parameters that exist (`SkillTests.skillsOnlyReferenceRealToolsAndParameters`).
- **No Claude attribution in git.** Commit messages and pull request descriptions carry no `Co-Authored-By: Claude`
  trailer and no "Generated with Claude Code" line.
- CI's compiler (Swift 6.2) is slower than local: build big `JSON.obj` literals in typed steps
  (`-Xfrontend -warn-long-expression-type-checking=60` finds them).
- **The panel looks like Apple Mail MCP's** (same `Views.swift` building blocks, segmented tab bar, orange-bordered
  approval block): Liquid Glass only on buttons (`glassButton`), over the system's glass menu window. Glass on a
  selection behind a label made the label unreadable; and `--snapshot` bitmaps cannot hold glass (the window server
  composites it), so they would show blank areas.

## EventKit facts this code depends on

- `eventIdentifier` is shared by every occurrence of a repeating event; tools name one occurrence
  `<eventIdentifier>#<unix seconds of its original start>` (`EventRef`), found again through a date query.
- Calendar's `ical://ekevent/<eventIdentifier>` shows a series' first occurrence. One occurrence is
  `ical://occurrence/<original start yyyyMMdd'T'HHmmss'Z'>/<calendarItemIdentifier>` (UTC; wall clock for floating
  events), and Calendar finds it only among the days on screen: open `ical://date/yyyy-MM-dd_HH-mm-ss` (UTC) first,
  in the same open request, and send the occurrence link again a moment later: Calendar drops it while the new day's
  events load (`NSWorkspace.showInCalendar(_:)`).
- `predicateForEvents` answers at most four years per query (`events(in:_:)` chunks).
- All-day events end at 23:59:59 of their last day; iCalendar ends them at the next midnight.
- Calendar has no Trash for events: undo recreates a deleted event from the journal, without its attendees.
- Answering: set `participationStatus` (KVC) and save; the account delivers the reply (checked: Google CalDAV
  invitee, iCloud organizer). `canBeRespondedTo` is false even for answerable invitations: gate on
  `allowsParticipationStatusModifications`. `allowsResponseCommentModifications` is false for Google.

## Releases

Same as Apple Mail MCP: publishing a GitHub release `vX.Y.Z` runs `.github/workflows/release.yml` (tests, universal
build, Developer ID signing, notarized `AppleCalendarMCP-X.Y.Z.dmg` and `.mcpb`, MCP registry). Bump
`CalendarMCPVersion.current` and `CHANGELOG.md` first. Secrets: `DEVELOPER_ID_CERTIFICATE`,
`DEVELOPER_ID_CERTIFICATE_PASSWORD`, `APPLE_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`.
