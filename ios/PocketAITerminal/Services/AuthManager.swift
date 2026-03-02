import Foundation
import Observation

@Observable
final class AuthManager {
    /// In-memory only — never persisted.
    private(set) var accessToken: String?
    private var tokenExpiresAt: Date?
    private var refreshTimer: Timer?
    private var baseURL: String = "http://localhost:8000"

    var isAuthenticated: Bool { accessToken != nil }

    struct TokenResponse: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    // MARK: - Login with dev token

    func login(devToken: String, baseURL: String) async throws {
        self.baseURL = baseURL
        let url = URL(string: "\(baseURL)/auth/dev-token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": devToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AuthError.loginFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        applyTokens(tokenResponse)
    }

    // MARK: - Refresh

    func refresh() async throws {
        guard let refreshData = try KeychainService.loadRefreshToken(),
              let refreshToken = String(data: refreshData, encoding: .utf8) else {
            throw AuthError.noRefreshToken
        }

        let url = URL(string: "\(baseURL)/auth/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["refresh_token": refreshToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AuthError.refreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        applyTokens(tokenResponse)
    }

    // MARK: - Proactive refresh (5 min before expiry)

    func scheduleProactiveRefresh() {
        refreshTimer?.invalidate()
        guard let expiresAt = tokenExpiresAt else { return }

        let refreshAt = expiresAt.addingTimeInterval(-300) // 5 min before
        let delay = max(0, refreshAt.timeIntervalSinceNow)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { [weak self] in
                try? await self?.refresh()
            }
        }
    }

    // MARK: - Logout

    func logout() {
        accessToken = nil
        tokenExpiresAt = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        try? KeychainService.deleteRefreshToken()
    }

    // MARK: - Helpers

    private func applyTokens(_ response: TokenResponse) {
        accessToken = response.accessToken
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))

        // Store refresh token in Keychain as Data
        var tokenData = Data(response.refreshToken.utf8)
        try? KeychainService.saveRefreshToken(tokenData)
        // Zero the local copy
        tokenData.resetBytes(in: 0..<tokenData.count)

        scheduleProactiveRefresh()
    }

    enum AuthError: Error, LocalizedError {
        case loginFailed
        case refreshFailed
        case noRefreshToken

        var errorDescription: String? {
            switch self {
            case .loginFailed: "Login failed. Check your dev token."
            case .refreshFailed: "Session expired. Please log in again."
            case .noRefreshToken: "No refresh token available."
            }
        }
    }
}
