import Foundation

final class APIClient {
    private let authManager: AuthManager
    private let baseURL: () -> String

    init(authManager: AuthManager, baseURL: @escaping () -> String) {
        self.authManager = authManager
        self.baseURL = baseURL
    }

    // MARK: - Sessions

    func getSessions() async throws -> [Session] {
        try await get("/sessions")
    }

    struct CreateSessionRequest: Encodable {
        let provider: String
        let apiKey: String

        enum CodingKeys: String, CodingKey {
            case provider
            case apiKey = "api_key"
        }
    }

    func createSession(provider: String, apiKey: String) async throws -> Session {
        let body = CreateSessionRequest(provider: provider, apiKey: apiKey)
        return try await post("/sessions", body: body)
    }

    func resumeSession(id: String) async throws -> Session {
        try await post("/sessions/\(id)/resume", body: Empty?.none)
    }

    func sleepSession(id: String) async throws -> Session {
        try await post("/sessions/\(id)/sleep", body: Empty?.none)
    }

    func deleteSession(id: String) async throws {
        let _: [String: String] = try await delete("/sessions/\(id)")
    }

    // MARK: - Uploads

    struct UploadedFile: Codable {
        let name: String
        let path: String
        let size: Int
    }

    struct UploadResponse: Codable {
        let uploaded: [UploadedFile]
    }

    func uploadFiles(
        _ files: [(filename: String, data: Data)],
        sessionId: String
    ) async throws -> UploadResponse {
        guard let url = URL(string: "\(baseURL())/sessions/\(sessionId)/upload") else {
            throw APIError.invalidURL
        }

        let boundary = "PAT-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let token = authManager.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Build multipart body
        var body = Data()
        for file in files {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(file.filename)\"\r\n")
            body.append("Content-Type: application/octet-stream\r\n\r\n")
            body.append(file.data)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Upload failed"
            throw APIError.serverError(
                (response as? HTTPURLResponse)?.statusCode ?? 500, msg
            )
        }

        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    // MARK: - HTTP Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = try makeRequest(path, method: "GET")
        return try await execute(request)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B?) async throws -> T {
        var request = try makeRequest(path, method: "POST")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        return try await execute(request)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        let request = try makeRequest(path, method: "DELETE")
        return try await execute(request)
    }

    private func makeRequest(_ path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL())\(path)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = authManager.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return try JSONDecoder().decode(T.self, from: data)
        case 401:
            // Try refreshing token once
            try await authManager.refresh()
            var retryRequest = request
            if let token = authManager.accessToken {
                retryRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard let retryHttp = retryResponse as? HTTPURLResponse,
                  (200..<300).contains(retryHttp.statusCode) else {
                throw APIError.unauthorized
            }
            return try JSONDecoder().decode(T.self, from: retryData)
        case 404:
            throw APIError.notFound
        case 429:
            throw APIError.rateLimited
        default:
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.serverError(httpResponse.statusCode, message)
        }
    }

    private struct Empty: Encodable {}

    enum APIError: Error, LocalizedError {
        case invalidURL
        case invalidResponse
        case unauthorized
        case notFound
        case rateLimited
        case serverError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid server URL."
            case .invalidResponse: "Invalid response from server."
            case .unauthorized: "Authentication required."
            case .notFound: "Resource not found."
            case .rateLimited: "Too many requests. Try again later."
            case .serverError(let code, let msg): "Server error (\(code)): \(msg)"
            }
        }
    }
}

// MARK: - Multipart Helper

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
