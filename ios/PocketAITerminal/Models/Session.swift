import Foundation

enum SessionStatus: String, Codable {
    case active
    case sleeping
    case stopped
}

struct Session: Codable, Identifiable {
    let sessionId: String
    let status: SessionStatus
    let createdAt: String
    let lastActive: String
    var wsTicket: String?

    var id: String { sessionId }

    /// Display-friendly truncated session ID.
    var shortId: String {
        String(sessionId.prefix(8))
    }

    /// Parsed last-active date, or nil if unparseable.
    var lastActiveDate: Date? {
        ISO8601DateFormatter().date(from: lastActive)
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case status
        case createdAt = "created_at"
        case lastActive = "last_active"
        case wsTicket = "ws_ticket"
    }
}
