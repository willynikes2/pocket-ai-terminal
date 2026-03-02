import Foundation
import Security

enum KeychainService {
    // Service identifiers
    static let apiKeysService = "com.pocket-ai-terminal.api-keys"
    static let refreshTokenService = "com.pocket-ai-terminal.refresh-token"

    // Well-known account keys
    static let anthropicKeyAccount = "ANTHROPIC_API_KEY"
    static let openaiKeyAccount = "OPENAI_API_KEY"
    static let refreshTokenAccount = "refresh-token"

    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
        case dataConversionFailed
    }

    // MARK: - API Keys (highest security, passcode-required, device-bound)

    static func saveAPIKey(_ value: Data, account: String) throws {
        try save(
            value: value,
            service: apiKeysService,
            account: account,
            accessibility: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        )
    }

    static func loadAPIKey(account: String) throws -> Data? {
        try load(service: apiKeysService, account: account)
    }

    static func deleteAPIKey(account: String) throws {
        try delete(service: apiKeysService, account: account)
    }

    // MARK: - Refresh Token (device-bound, available when unlocked)

    static func saveRefreshToken(_ value: Data) throws {
        try save(
            value: value,
            service: refreshTokenService,
            account: refreshTokenAccount,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    static func loadRefreshToken() throws -> Data? {
        try load(service: refreshTokenService, account: refreshTokenAccount)
    }

    static func deleteRefreshToken() throws {
        try delete(service: refreshTokenService, account: refreshTokenAccount)
    }

    // MARK: - Generic Operations

    private static func save(
        value: Data,
        service: String,
        account: String,
        accessibility: CFString
    ) throws {
        // Delete existing item first to avoid duplicates
        try? delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: accessibility,
            kSecValueData as String: value,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private static func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status)
        }
        return result as? Data
    }

    private static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Delete all items for both services.
    static func resetAll() {
        try? delete(service: apiKeysService, account: anthropicKeyAccount)
        try? delete(service: apiKeysService, account: openaiKeyAccount)
        try? delete(service: refreshTokenService, account: refreshTokenAccount)
    }
}
