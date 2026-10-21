import CryptoKit
import Foundation
import Security

// The menu bar app holds the Calendars permission (macOS asks the app that starts a process, and Claude, a terminal or
// an editor cannot be given it for our server). Servers reach EventKit through the app over a Unix socket in the
// owner-only support folder. Both ends check the other's code signature, so the socket hands calendar data only to
// this project's own server, and a server only believes this project's own app.

/// What one end requires of the code at the other end of the bridge.
public struct PeerRequirement: Sendable, CustomStringConvertible {
    /// A code requirement (`csreq` language); nil accepts any process of this user (tests only).
    let text: String?

    init(text: String?) { self.text = text }

    /// Tests: any process of this user. Never used by the app or the server.
    static let anyProcessForTesting = PeerRequirement(text: nil)

    public var description: String { text ?? "any process of this user" }

    /// The bundle identifiers of the app, its server and the standalone server (`.mcpb`).
    public static let identifiers = ["com.mpconsulting.AppleCalendarMCP", "com.mpconsulting.AppleCalendarMCP.Server", "apple-calendar-mcp"]

    /// Code signed the way this process is: by the same team (Developer ID or Apple Development), else by the same
    /// certificate (the local signing identity of development builds), with one of `identifiers`. Ad-hoc signed or
    /// unsigned code has no stable identity: such builds cannot use the bridge.
    public static func matchingSelf(identifiers: [String] = identifiers) throws -> PeerRequirement {
        let names = "(" + identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ") + ")"
        let info = try CodeSigning.ownInfo()
        if let team = info.team {
            return PeerRequirement(text: "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and \(names)")
        }
        if let leaf = info.leafSHA1 {
            return PeerRequirement(text: "certificate leaf = H\"\(leaf)\" and \(names)")
        }
        throw CalendarError(
            "This build is not signed with a certificate (ad-hoc), so it cannot talk to the Apple Calendar MCP app. "
                + "Sign it with Scripts/create-signing-identity.sh and Scripts/build-app.sh.")
    }
}

enum CodeSigning {
    struct Info {
        var team: String?
        var leafSHA1: String?
    }

    static func ownInfo() throws -> Info {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { throw unreadableSignature() }
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
            let values = dictionary as? [String: Any]
        else { throw unreadableSignature() }
        let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        let leaf = (values[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first.map { certificate in
            Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
        }
        return Info(team: team, leafSHA1: leaf)
    }

    /// The signature is read from the file on disk: a server still running after its app was moved, updated or
    /// deleted has none left to read. The client must start the new one.
    private static func unreadableSignature() -> CalendarError {
        if let path = Bundle.main.executablePath, !FileManager.default.fileExists(atPath: path) {
            return CalendarError(
                "This server's program was moved, updated or deleted while it was running (\(path)). "
                    + "Restart the MCP client (quit and reopen Claude) to start the installed version.")
        }
        return CalendarError("Could not read this program's code signature.")
    }

    /// Whether the process at the other end of the connected socket `fd` runs as this user and meets `requirement`.
    static func peer(of fd: Int32, satisfies requirement: PeerRequirement) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        guard let text = requirement.text else { return true }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        var compiled: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
            let code, SecRequirementCreateWithString(text as CFString, [], &compiled) == errSecSuccess, let compiled
        else { return false }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}

/// One request over the bridge.
enum BridgeRequest: Codable, Sendable {
    case hello
    case access
    case calendars
    case events(start: Date, end: Date, calendarIDs: [String]?)
    case event(EventRef)
    case create(EventDraft)
    case update(EventRef, EventChange, Span)
    case delete(EventRef, Span)
    case changeCount
    case approve(ApprovalRequest, timeout: TimeInterval)
}

/// The answer: the field matching the request, or `error`.
struct BridgeResponse: Codable, Sendable {
    var error: String?
    var info: BridgeInfo?
    var access: AccessState?
    var calendars: [CalendarInfo]?
    var events: [Event]?
    var event: Event?
    var count: Int?
    var decision: ApprovalDecision?
}

/// Who answers at the other end.
public struct BridgeInfo: Codable, Sendable, Equatable {
    public var version: String
    public var pid: Int32

    public init(version: String, pid: Int32) {
        self.version = version
        self.pid = pid
    }
}

enum BridgeCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// Newline-delimited JSON over a connected socket.
struct LineSocket {
    let fd: Int32
    private var buffer: [UInt8] = []

    init(fd: Int32) { self.fd = fd }

    mutating func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[..<newline])
                buffer.removeFirst(newline + 1)
                return line
            }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
            if buffer.count > 256 * 1_048_576 { return nil }
        }
    }

    func write(line: Data) -> Bool {
        var message = line
        message.append(UInt8(ascii: "\n"))
        return message.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw CalendarError("The bridge socket path is too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}

// MARK: Host (the menu bar app)

/// Serves a backend (EventKit in the app) and the approval prompts to verified servers.
public final class BridgeHost: @unchecked Sendable {
    public typealias Approver = @Sendable (ApprovalRequest, TimeInterval) async -> ApprovalDecision

    public let socket: URL
    private let backend: any CalendarBackend
    private let requirement: PeerRequirement
    private let approver: Approver
    private let info: BridgeInfo
    private let lock = NSLock()
    private var listener: Int32 = -1
    /// Connections turned away because the code at the other end was not ours (shown by `doctor` and the app).
    public private(set) var refusedPeers = 0

    public init(socket: URL, backend: any CalendarBackend, requirement: PeerRequirement, info: BridgeInfo, approver: @escaping Approver) {
        self.socket = socket
        self.backend = backend
        self.requirement = requirement
        self.info = info
        self.approver = approver
    }

    public func start() throws {
        let folder = socket.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chmod(folder.path, 0o700)
        unlink(socket.path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CalendarError("Could not create the bridge socket (errno \(errno)).") }
        var address = try LineSocket.address(socket.path)
        // Owner-only from the start: no window in which another user could connect.
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(previous)
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw CalendarError("Could not listen on \(socket.path) (errno \(errno)).")
        }
        lock.withLock { listener = fd }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "apple-calendar-mcp bridge"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func stop() {
        let fd = lock.withLock {
            defer { listener = -1 }
            return listener
        }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(socket.path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // stopped
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            guard CodeSigning.peer(of: client, satisfies: requirement) else {
                lock.withLock { refusedPeers += 1 }
                close(client)
                continue
            }
            Thread.detachNewThread { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        var connection = LineSocket(fd: fd)
        while let line = connection.readLine() {
            let response: BridgeResponse
            if let request = try? BridgeCoding.decoder.decode(BridgeRequest.self, from: line) {
                response = handle(request)
            } else {
                response = BridgeResponse(error: "unreadable request")
            }
            guard let data = try? BridgeCoding.encoder.encode(response), connection.write(line: data) else { return }
        }
    }

    func handle(_ request: BridgeRequest) -> BridgeResponse {
        do {
            switch request {
            case .hello: return BridgeResponse(info: info, access: backend.access())
            case .access: return BridgeResponse(access: backend.access())
            case .calendars: return BridgeResponse(calendars: try backend.calendars())
            case let .events(start, end, ids): return BridgeResponse(events: try backend.events(from: start, to: end, calendarIDs: ids))
            case .event(let ref): return BridgeResponse(event: try backend.event(ref))
            case .create(let draft): return BridgeResponse(event: try backend.create(draft))
            case let .update(ref, change, span): return BridgeResponse(event: try backend.update(ref, change, span: span))
            case let .delete(ref, span):
                try backend.delete(ref, span: span)
                return BridgeResponse()
            case .changeCount: return BridgeResponse(count: backend.changeCount())
            case let .approve(approval, timeout):
                let box = DecisionBox()
                let semaphore = DispatchSemaphore(value: 0)
                let approver = self.approver
                Task {
                    box.value = await approver(approval, timeout)
                    semaphore.signal()
                }
                semaphore.wait()
                return BridgeResponse(decision: box.value)
            }
        } catch {
            return BridgeResponse(error: String(describing: error))
        }
    }
}

private final class DecisionBox: @unchecked Sendable {
    var value: ApprovalDecision = .timedOut
}

// MARK: Client (the server)

/// Talks to the app's bridge; starts the app when nobody answers.
public final class BridgeClient: @unchecked Sendable {
    public let socket: URL
    private let requirement: PeerRequirement
    /// Opens the menu bar app (in the background); nil when there is no app to open.
    private let launcher: (@Sendable () throws -> Void)?
    private let lock = NSLock()
    private var launched = false

    public init(socket: URL, requirement: PeerRequirement, launcher: (@Sendable () throws -> Void)?) {
        self.socket = socket
        self.requirement = requirement
        self.launcher = launcher
    }

    /// One request and its answer, on a fresh connection. `timeout` bounds the wait for the answer.
    func send(_ request: BridgeRequest, timeout: TimeInterval = 30) throws -> BridgeResponse {
        let fd = try connectOrLaunch()
        defer { close(fd) }
        var seconds = timeval(tv_sec: Int(timeout.rounded(.up)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
        var connection = LineSocket(fd: fd)
        guard connection.write(line: try BridgeCoding.encoder.encode(request)), let line = connection.readLine() else {
            throw CalendarError("The Apple Calendar MCP app stopped answering.")
        }
        let response = try BridgeCoding.decoder.decode(BridgeResponse.self, from: line)
        if let error = response.error { throw CalendarError(error) }
        return response
    }

    private func connectOrLaunch() throws -> Int32 {
        if let fd = try connect() { return fd }
        guard let launcher else {
            throw CalendarError("The Apple Calendar MCP app is not running. Open it: it holds the Calendars permission.")
        }
        let first = lock.withLock {
            defer { launched = true }
            return !launched
        }
        if first { try launcher() }
        // An app that starts takes a moment to open its socket.
        let deadline = Date().addingTimeInterval(first ? 20 : 3)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            if let fd = try connect() { return fd }
        }
        throw CalendarError("The Apple Calendar MCP app did not start. Open it from Applications: it holds the Calendars permission.")
    }

    /// A verified connection, or nil when nobody listens.
    private func connect() throws -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CalendarError("Could not create a socket (errno \(errno)).") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = try LineSocket.address(socket.path)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else {
            close(fd)
            return nil
        }
        guard CodeSigning.peer(of: fd, satisfies: requirement) else {
            close(fd)
            throw CalendarError(
                "Something other than the Apple Calendar MCP app answers on \(socket.path); not sending it anything. Quit it, then open the app again.")
        }
        return fd
    }

    public func hello() throws -> (BridgeInfo, AccessState) {
        let response = try send(.hello, timeout: 10)
        guard let info = response.info, let access = response.access else { throw CalendarError("The app sent an incomplete answer.") }
        return (info, access)
    }

    /// Asks the user in the app; waits up to `timeout` for the answer.
    public func requestApproval(_ request: ApprovalRequest, timeout: TimeInterval) throws -> ApprovalDecision {
        try send(.approve(request, timeout: timeout), timeout: timeout + 15).decision ?? .timedOut
    }

    /// Whether something answers on the socket, without starting the app.
    public var isAppRunning: Bool {
        guard let fd = try? connect() else { return false }
        close(fd)
        return true
    }
}

/// Calendar through the menu bar app.
public final class BridgeBackend: CalendarBackend, @unchecked Sendable {
    public let client: BridgeClient

    public init(client: BridgeClient) { self.client = client }

    public func access() -> AccessState {
        do {
            return try client.send(.access, timeout: 10).access ?? .unavailable("The app did not say.")
        } catch {
            return .unavailable(String(describing: error))
        }
    }

    public func calendars() throws -> [CalendarInfo] { try client.send(.calendars).calendars ?? [] }

    public func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [Event] {
        try client.send(.events(start: start, end: end, calendarIDs: calendarIDs), timeout: 60).events ?? []
    }

    public func event(_ ref: EventRef) throws -> Event? { try client.send(.event(ref)).event }

    public func create(_ draft: EventDraft) throws -> Event {
        guard let event = try client.send(.create(draft)).event else { throw CalendarError("The app did not return the new event.") }
        return event
    }

    public func update(_ ref: EventRef, _ change: EventChange, span: Span) throws -> Event {
        guard let event = try client.send(.update(ref, change, span)).event else { throw CalendarError("The app did not return the event.") }
        return event
    }

    public func delete(_ ref: EventRef, span: Span) throws { _ = try client.send(.delete(ref, span)) }

    public func changeCount() -> Int { (try? client.send(.changeCount, timeout: 5).count) ?? 0 }
}
