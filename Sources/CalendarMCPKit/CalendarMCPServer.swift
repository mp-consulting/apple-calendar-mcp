import CalendarStore
import Foundation
import MCP

public enum CalendarMCPVersion {
    /// The app bundle's version when running from "Apple Calendar MCP.app" (stamped at release), else the source version.
    public static let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        .flatMap { $0.hasPrefix("__") ? nil : $0 } ?? "0.1.3"

    /// The commit this build was made from: stamped by `Scripts/build-app.sh` in the bundle (`AppleCalendarMCPCommit`),
    /// and passed by the Claude extension's manifest (`APPLE_CALENDAR_MCP_COMMIT`); nil for a plain `swift build`.
    public static let commit: String? = {
        let stamped = Bundle.main.infoDictionary?["AppleCalendarMCPCommit"] as? String
            ?? ProcessInfo.processInfo.environment["APPLE_CALENDAR_MCP_COMMIT"]
        return stamped.flatMap { $0.isEmpty || $0.hasPrefix("__") ? nil : $0 }
    }()

    /// The version with its build as semver build metadata (`0.1.0+1a2b3c4`, `+dev` for an unstamped build).
    public static let build = "\(current)+\(commit ?? "dev")"

    /// Whether `version` (a ``build`` string) is older than `reference`, ignoring the build; unreadable counts as older.
    public static func isOlder(_ version: String?, than reference: String = current) -> Bool {
        let release = { (text: String) in AppVersion(String(text.split(separator: "+", omittingEmptySubsequences: false)[0])) }
        guard let version, let ours = release(version), let theirs = release(reference) else { return true }
        return ours < theirs
    }
}

/// Binds a ``CalendarToolbox`` to an MCP `Server`.
public enum CalendarMCPServer {
    public static func make(toolbox: CalendarToolbox, watchInterval: TimeInterval = 30) async -> Server {
        let server = Server(
            name: "apple-calendar",
            version: CalendarMCPVersion.build,
            title: "Apple Calendar",
            instructions: CalendarToolbox.instructions,
            capabilities: .init(
                prompts: .init(listChanged: false), resources: .init(subscribe: true, listChanged: false),
                tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: toolbox.listedDefinitions.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { params in
            await toolbox.call(params.name, arguments: params.arguments)
        }
        let resources = CalendarResources(toolbox: toolbox)
        await server.withMethodHandler(ListResources.self) { _ in ListResources.Result(resources: resources.resources) }
        await server.withMethodHandler(ReadResource.self) { params in try await resources.read(params.uri) }
        await server.withMethodHandler(ResourceSubscribe.self) { params in
            try resources.subscribe(params.uri)
            await resources.prime(params.uri)  // remember the current state; changes from here on are news
            return Empty()
        }
        await server.withMethodHandler(ResourceUnsubscribe.self) { params in
            resources.unsubscribe(params.uri)
            return Empty()
        }
        // Nothing is read unless someone subscribed.
        Task { [weak server] in
            while let server, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(watchInterval * 1_000_000_000))
                for uri in await resources.changedSubscriptions() {
                    try? await server.notify(ResourceUpdatedNotification.message(.init(uri: uri)))
                }
            }
        }
        await server.withMethodHandler(ListPrompts.self) { _ in ListPrompts.Result(prompts: toolbox.prompts) }
        await server.withMethodHandler(GetPrompt.self) { params in
            try toolbox.prompt(named: params.name, arguments: params.arguments)
        }
        return server
    }

    /// Runs over stdio until the client disconnects.
    public static func runStdio(toolbox: CalendarToolbox) async throws {
        let server = await make(toolbox: toolbox)
        // Tool calls skip the SDK's request decoding (see `ToolCallFastPath`); everything else goes through it.
        let running = RunningCalls()
        let transport = LineTransport(intercept: { line, transport in
            guard let call = ToolCallFastPath.call(in: line) else {
                // A call the client gave up on stops between events.
                if let id = ToolCallFastPath.cancelledRequest(in: line) { running.cancel(id) }
                return false
            }
            running.start(call.id) {
                Task(priority: .userInitiated) {
                    defer { running.remove(call.id) }
                    let result = await toolbox.call(call.name, arguments: call.arguments)
                    if let reply = try? ToolCallFastPath.reply(to: call, result: result) { try? transport.write(line: reply) }
                }
            }
            return true
        })
        try await server.start(transport: transport) { clientInfo, _ in
            toolbox.clientName = clientInfo.title ?? clientInfo.name
        }
        await server.waitUntilCompleted()
        toolbox.activity?.flush()
    }
}

/// Tool calls in progress by request id (as JSON), so a `notifications/cancelled` can cancel their task.
final class RunningCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Data: Task<Void, Never>] = [:]
    private var cancelled: Set<Data> = []

    /// Starts the call's task under the lock, so its `remove` cannot come first.
    func start(_ id: Data, _ make: () -> Task<Void, Never>) {
        lock.withLock {
            let task = make()
            if cancelled.remove(id) != nil { task.cancel() }
            tasks[id] = task
        }
    }

    func remove(_ id: Data) { _ = lock.withLock { tasks.removeValue(forKey: id) } }

    func cancel(_ id: Data) {
        lock.withLock {
            if let task = tasks.removeValue(forKey: id) {
                task.cancel()
            } else {
                if cancelled.count > 100 { cancelled.removeAll() }
                cancelled.insert(id)
            }
        }
    }
}

/// `calendar://today` and `calendar://upcoming`: the agenda as JSON, with change notifications for subscribers.
final class CalendarResources: @unchecked Sendable {
    let toolbox: CalendarToolbox
    private let lock = NSLock()
    private var subscribed: [String: String] = [:]  // uri -> last content seen
    private var seenChangeCount: Int?
    private var lastLook = Date.distantPast

    /// Agendas hold time-based fields (next event, free time left): look again this often even when nothing changed.
    static let staleAfter: TimeInterval = 15 * 60

    init(toolbox: CalendarToolbox) { self.toolbox = toolbox }

    static let today = "calendar://today"
    static let upcoming = "calendar://upcoming"

    var resources: [Resource] {
        [
            Resource(name: "Today", uri: Self.today, description: "Today's events, conflicts, free time and open invitations", mimeType: "application/json"),
            Resource(name: "Next 7 days", uri: Self.upcoming, description: "The events of the next 7 days", mimeType: "application/json"),
        ]
    }

    func content(_ uri: String) async throws -> String {
        let arguments: [String: Value]
        switch uri {
        case Self.today: arguments = ["days": 1]
        case Self.upcoming: arguments = ["days": 7]
        default: throw MCPError.invalidParams("Unknown resource \(uri)")
        }
        let result = await toolbox.call("agenda", arguments: arguments, logged: false)
        guard case .text(let text, _, _)? = result.content.first, result.isError != true else {
            throw MCPError.internalError("The calendar could not be read.")
        }
        return text
    }

    func read(_ uri: String) async throws -> ReadResource.Result {
        ReadResource.Result(contents: [.text(try await content(uri), uri: uri, mimeType: "application/json")])
    }

    func subscribe(_ uri: String) throws {
        guard [Self.today, Self.upcoming].contains(uri) else { throw MCPError.invalidParams("Unknown resource \(uri)") }
        lock.withLock { if subscribed[uri] == nil { subscribed[uri] = "" } }
    }

    func unsubscribe(_ uri: String) { _ = lock.withLock { subscribed.removeValue(forKey: uri) } }

    func prime(_ uri: String) async {
        guard let text = try? await content(uri) else { return }
        lock.withLock { if subscribed[uri] != nil { subscribed[uri] = text } }
    }

    /// The subscribed resources whose content changed since the last look. The agendas are only recomputed when the
    /// calendar database changed, the day turned, or `staleAfter` passed.
    func changedSubscriptions() async -> [String] {
        let uris = lock.withLock { Array(subscribed.keys) }
        guard !uris.isEmpty else { return [] }
        let count = try? toolbox.backend.changeCount()
        let now = toolbox.now()
        let due = lock.withLock {
            let due = count == nil || count != seenChangeCount || !Calendar.current.isDate(lastLook, inSameDayAs: now)
                || now.timeIntervalSince(lastLook) >= Self.staleAfter
            if due {
                seenChangeCount = count
                lastLook = now
            }
            return due
        }
        guard due else { return [] }
        var changed: [String] = []
        for uri in uris {
            guard let text = try? await content(uri) else { continue }
            let previous = lock.withLock {
                defer { if subscribed[uri] != nil { subscribed[uri] = text } }
                return subscribed[uri]
            }
            if let previous, !previous.isEmpty, previous != text { changed.append(uri) }
        }
        return changed
    }
}
