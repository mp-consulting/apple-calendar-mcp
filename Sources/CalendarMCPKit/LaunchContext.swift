import AppKit
import CalendarStore
import Foundation

/// How a server reaches the calendar: EventKit right here when this process may read calendars (a terminal that has
/// Calendars access), else EventKit in the menu bar app over the bridge, which the server opens when needed.
public enum LaunchContext {
    public static let appBundleID = "com.mpconsulting.AppleCalendarMCP"

    /// The backend for a server process.
    public static func backend(socket: URL = SharedPaths.bridgeSocket) -> any CalendarBackend {
        if EventKitBackend.authorization() == .granted { return EventKitBackend() }
        do {
            return BridgeBackend(client: try bridgeClient(socket: socket))
        } catch {
            return UnavailableBackend(reason: String(describing: error))
        }
    }

    /// A client for the app's bridge that opens the app when it is not running.
    public static func bridgeClient(socket: URL = SharedPaths.bridgeSocket) throws -> BridgeClient {
        BridgeClient(socket: socket, requirement: try PeerRequirement.matchingSelf(), launcher: { try openApp() })
    }

    /// Asks the user through the app (which is opened if needed).
    public static func approver(socket: URL = SharedPaths.bridgeSocket) -> Approver {
        { request, timeout in try bridgeClient(socket: socket).requestApproval(request, timeout: timeout) }
    }

    /// The menu bar app: the one this server sits in, else the one Launch Services knows.
    public static func appURL() -> URL? {
        var url = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app", Bundle(url: url)?.bundleIdentifier == appBundleID { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID)
    }

    /// Opens the menu bar app in the background (it shows no window on launch).
    static func openApp() throws {
        guard let url = appURL() else {
            throw CalendarError(
                "The Apple Calendar MCP app is not installed. It holds the Calendars permission: install it from "
                    + "https://github.com/mp-consulting/apple-calendar-mcp/releases and open it once.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}

/// A backend that explains, on every call, why there is no calendar.
public struct UnavailableBackend: CalendarBackend {
    public let reason: String

    public init(reason: String) { self.reason = reason }

    public func access() -> AccessState { .unavailable(reason) }
    public func calendars() throws -> [CalendarInfo] { throw CalendarError(reason) }
    public func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [Event] { throw CalendarError(reason) }
    public func event(_ ref: EventRef) throws -> Event? { throw CalendarError(reason) }
    public func create(_ draft: EventDraft) throws -> Event { throw CalendarError(reason) }
    public func update(_ ref: EventRef, _ change: EventChange, span: Span) throws -> Event { throw CalendarError(reason) }
    public func delete(_ ref: EventRef, span: Span) throws { throw CalendarError(reason) }
    public func invitationCheck(_ ref: EventRef) throws -> InvitationCheck { throw CalendarError(reason) }
    public func respond(_ ref: EventRef, _ answer: InvitationAnswer) throws -> Event { throw CalendarError(reason) }
    public func changeCount() -> Int { 0 }
}
