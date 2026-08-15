import Foundation

#if canImport(Security)
import Security

/// Device-local vault. Apple credentials and FUMINIWA refresh tokens never
/// enter SQLite, `.novelpkg`, URLSession caches, or diagnostic logs.
public actor KeychainAuthSessionVault: AuthSessionVault {
    private let service: String
    private let account: String

    public init(service: String = "jp.fuminiwa.sync", account: String = "session") {
        self.service = service
        self.account = account
    }

    public func load() async throws -> FuminiwaSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainAuthError.status(status)
        }
        return try JSONDecoder().decode(FuminiwaSession.self, from: data)
    }

    public func save(_ session: FuminiwaSession) async throws {
        let data = try JSONEncoder().encode(session)
        var updateQuery = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainAuthError.status(updateStatus)
        }
        updateQuery[kSecValueData as String] = data
        updateQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(updateQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainAuthError.status(addStatus)
        }
    }

    public func remove() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAuthError.status(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum KeychainAuthError: Error, Equatable, Sendable {
    case status(OSStatus)
}
#endif
