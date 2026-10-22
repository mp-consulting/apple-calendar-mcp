import Foundation

/// Something a tool wants to do that waits for the user's OK in the menu bar app.
public struct ApprovalRequest: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Delete events (Calendar has no Trash); `attendees` lists who may hear about it.
        case delete
        /// Change events other people are invited to: their calendar server may tell them.
        case notify
    }

    public var id: UUID
    public var created: Date
    public var tool: String
    public var client: String?
    public var kind: Kind
    /// What is asked, in a few words: an event's title, or "3 events".
    public var title: String
    /// The events concerned, one line each ("Tue 21 Oct 14:00–15:00 · Design review · Work").
    public var items: [String]
    /// People who may hear about it.
    public var attendees: [String]
    /// What changes, when it is a change ("Moves to Wed 22 Oct 10:00").
    public var detail: String?

    public init(
        id: UUID = UUID(), created: Date = Date(), tool: String, client: String?, kind: Kind, title: String, items: [String],
        attendees: [String] = [], detail: String? = nil
    ) {
        self.id = id
        self.created = created
        self.tool = tool
        self.client = client
        self.kind = kind
        self.title = title
        self.items = items
        self.attendees = attendees
        self.detail = detail
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case approved, denied, timedOut
}
