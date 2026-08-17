import Foundation

#if canImport(Security)
import Security

/// Device-local vault.  Pending refresh rotation identifiers are durable in
/// the same Keychain record, allowing a process restart to avoid inventing a
/// second rotation for a request whose response was lost.
public actor KeychainAuthSessionVault: AuthSessionVault {
    private struct Record: Codable, Sendable {
        var session: FuminiwaSession
        var pendingRotationIDs: [UUID]
    }

    private let service: String
    private let account: String
    public init(service: String = "jp.fuminiwa.sync", account: String = "session") {
        self.service = service; self.account = account
    }

    public func load() async throws -> FuminiwaSession? {
        try read()?.session
    }

    public func save(_ session: FuminiwaSession) async throws {
        try write(Record(session: session, pendingRotationIDs: read()?.pendingRotationIDs ?? []))
    }

    public func remove() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainAuthError.status(status) }
    }

    public func reserveRefreshRotation(_ rotationID: UUID, for session: FuminiwaSession) async throws {
        guard let current = try read(), current.session == session else { throw AuthError.staleResponse }
        guard !current.pendingRotationIDs.contains(rotationID) else { throw AuthError.duplicateRotation }
        var next = current; next.pendingRotationIDs.append(rotationID); try write(next)
    }

    public func compareAndSwap(expectedRefreshToken: String, expectedGeneration: UInt64, replacing session: FuminiwaSession) async throws -> Bool {
        guard var current = try read(), current.session.refreshToken == expectedRefreshToken, current.session.refreshGeneration == expectedGeneration else { return false }
        current.session = session; current.pendingRotationIDs.removeAll(); try write(current); return true
    }

    private func read() throws -> Record? {
        var query = baseQuery(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainAuthError.status(status) }
        do { return try JSONDecoder().decode(Record.self, from: data) } catch { throw KeychainAuthError.invalidRecord }
    }

    private func write(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else { throw KeychainAuthError.status(updateStatus) }
        var query = baseQuery(); query[kSecValueData as String] = data; query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil); guard addStatus == errSecSuccess else { throw KeychainAuthError.status(addStatus) }
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

public enum KeychainAuthError: Error, Equatable, Sendable { case status(OSStatus), invalidRecord }
#endif
