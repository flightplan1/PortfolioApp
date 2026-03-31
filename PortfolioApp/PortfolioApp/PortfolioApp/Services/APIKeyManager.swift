import Foundation
import Security

// MARK: - API Key Manager
// All API keys stored in iOS Keychain only — never hardcoded, never UserDefaults.

extension Notification.Name {
    static let finnhubKeyDidChange = Notification.Name("finnhubKeyDidChange")
}

enum APIKeyError: LocalizedError {
    case notFound
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notFound:         return "API key not found. Please add your Finnhub key in Settings."
        case .saveFailed(let s): return "Failed to save API key (OSStatus \(s))"
        case .deleteFailed(let s): return "Failed to delete API key (OSStatus \(s))"
        case .encodingFailed:   return "Failed to encode API key"
        }
    }
}

struct APIKeyManager {

    // MARK: - Service Keys

    private enum Service: String {
        case finnhub = "com.portfolioapp.apikey.finnhub"
        // CoinGecko free tier requires no key
    }

    // MARK: - Finnhub

    static func saveFinnhubKey(_ key: String) throws {
        try save(key, service: .finnhub)
    }

    static func getFinnhubKey() throws -> String {
        try get(service: .finnhub)
    }

    static func deleteFinnhubKey() throws {
        try delete(service: .finnhub)
    }

    static var hasFinnhubKey: Bool {
        (try? getFinnhubKey()) != nil
    }

    // MARK: - Generic Keychain Operations

    private static func save(_ value: String, service: Service) throws {
        guard let data = value.data(using: .utf8) else {
            throw APIKeyError.encodingFailed
        }

        // Delete existing item first to allow update
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service.rawValue,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String:        data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw APIKeyError.saveFailed(status)
        }
    }

    private static func get(service: Service) throws -> String {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw APIKeyError.notFound
        }

        return key
    }

    private static func delete(service: Service) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyError.deleteFailed(status)
        }
    }
}
