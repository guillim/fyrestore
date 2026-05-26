import Foundation
import Security

/// Stores OAuthTokens as a JSON blob in the macOS login keychain.
struct KeychainTokenStore {
    private let service = "com.fyrestore.tokens"
    private let account = "default"

    func save(_ tokens: OAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Try to update the existing entry first — this is one keychain operation
        // (and one trust prompt for unsigned binaries) instead of the Delete+Add pair.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            // First-time save — create the item.
            var attrs = baseQuery
            attrs[kSecValueData as String] = data
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: "Keychain", code: Int(addStatus))
            }
            return
        }

        throw NSError(domain: "Keychain", code: Int(updateStatus))
    }

    func load() -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "Keychain", code: Int(status))
        }
    }
}
