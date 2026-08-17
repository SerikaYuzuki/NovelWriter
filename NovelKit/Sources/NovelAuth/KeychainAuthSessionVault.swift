import Foundation

#if canImport(Security)
import Security

/// Device-local vault. The serialized value is the pure AuthVaultRecord state
/// machine, so pending refresh and operation journals survive process death.
public actor KeychainAuthSessionVault: AuthSessionVault {
    private let service: String
    private let account: String

    public init(service: String = "jp.fuminiwa.sync", account: String = "session") {
        self.service = service
        self.account = account
    }

    public func load() async throws -> FuminiwaSession? {
        try readRecord().session
    }

    public func save(_ session: FuminiwaSession) async throws {
        var record = try readRecord()
        record.save(session)
        try writeRecord(record)
    }

    public func remove() async throws {
        var record = try readRecord()
        record.removeLocalSession()
        if record.session == nil, record.pendingRevoke == nil, record.operations.isEmpty {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainAuthError.status(status)
            }
        } else {
            try writeRecord(record)
        }
    }

    public func loadOrReserveRefreshRotation(proposed: UUID, for session: FuminiwaSession) async throws -> UUID {
        var record = try readRecord()
        let rotationID = try record.loadOrReserveRefreshRotation(proposed: proposed, for: session)
        try writeRecord(record)
        return rotationID
    }

    public func compareAndSwap(
        expectedRefreshToken: String,
        expectedGeneration: UInt64,
        rotationID: UUID,
        replacing session: FuminiwaSession
    ) async throws -> Bool {
        var record = try readRecord()
        guard record.compareAndSwap(
            expectedRefreshToken: expectedRefreshToken,
            expectedGeneration: expectedGeneration,
            rotationID: rotationID,
            replacing: session
        ) else { return false }
        try writeRecord(record)
        return true
    }

    public func loadOrReserveOperation(
        kind: AuthOperationKind,
        proposed: UUID,
        fingerprint: String
    ) async throws -> AuthOperationJournalEntry {
        var record = try readRecord()
        let entry = try record.loadOrReserveOperation(kind: kind, proposed: proposed, fingerprint: fingerprint)
        try writeRecord(record)
        return entry
    }

    public func beginOperation(
        kind: AuthOperationKind,
        operationID: UUID,
        fingerprint: String
    ) async throws -> AuthOperationJournalEntry {
        var record = try readRecord()
        let entry = try record.beginOperation(kind: kind, operationID: operationID, fingerprint: fingerprint)
        try writeRecord(record)
        return entry
    }

    public func clearOperation(kind: AuthOperationKind, operationID: UUID) async throws {
        var record = try readRecord()
        record.clearOperation(kind: kind, operationID: operationID)
        try writeRecord(record)
    }

    public func clearOperation(kind: AuthOperationKind, fingerprint: String) async throws {
        var record = try readRecord()
        record.clearOperation(kind: kind, fingerprint: fingerprint)
        try writeRecord(record)
    }

    public func bindOperationRequest(kind: AuthOperationKind, operationID: UUID, fingerprint: String, requestDigest: Data) async throws -> AuthOperationJournalEntry {
        var record = try readRecord()
        let entry = try record.bindOperationRequest(
            kind: kind,
            operationID: operationID,
            fingerprint: fingerprint,
            requestDigest: requestDigest
        )
        try writeRecord(record)
        return entry
    }

    public func loadPendingRevoke() async throws -> AuthPendingRevoke? {
        try readRecord().pendingRevoke
    }

    public func loadOrReserveRevokeOperation(proposed: UUID, for session: FuminiwaSession, now: Date, receiptLifetimeSeconds: UInt64) async throws -> AuthPendingRevoke {
        var record = try readRecord()
        let pending = try record.loadOrReserveRevokeOperation(proposed: proposed, for: session, now: now, receiptLifetimeSeconds: receiptLifetimeSeconds)
        try writeRecord(record)
        return pending
    }

    public func rollForwardExpiredRevokeOperation(proposed: UUID, now: Date, receiptLifetimeSeconds: UInt64) async throws -> AuthPendingRevoke {
        var record = try readRecord()
        let pending = try record.rollForwardExpiredRevokeOperation(
            proposed: proposed,
            now: now,
            receiptLifetimeSeconds: receiptLifetimeSeconds
        )
        try writeRecord(record)
        return pending
    }

    public func clearPendingRevoke(operationID: UUID) async throws {
        var record = try readRecord()
        record.clearPendingRevoke(operationID: operationID)
        if record.session == nil, record.pendingRevoke == nil, record.operations.isEmpty {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainAuthError.status(status)
            }
        } else {
            try writeRecord(record)
        }
    }

    private func readRecord() throws -> AuthVaultRecord {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return AuthVaultRecord()
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainAuthError.status(status)
        }
        do {
            return try JSONDecoder().decode(AuthVaultRecord.self, from: data)
        } catch {
            throw KeychainAuthError.invalidRecord
        }
    }

    private func writeRecord(_ record: AuthVaultRecord) throws {
        let data = try JSONEncoder().encode(record)
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainAuthError.status(updateStatus)
        }
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainAuthError.status(addStatus)
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
    case invalidRecord
}
#endif
