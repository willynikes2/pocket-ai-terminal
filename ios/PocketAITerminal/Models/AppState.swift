import Foundation
import Observation

@Observable
final class AppState {
    var sessions: [Session] = []
    var currentSession: Session?
    var isAuthenticated = false
    var baseURL = "http://localhost:8000"

    /// Update a session in the list or append if new.
    func upsertSession(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
    }

    /// Remove a session from the list.
    func removeSession(id: String) {
        sessions.removeAll { $0.sessionId == id }
        if currentSession?.sessionId == id {
            currentSession = nil
        }
    }
}
