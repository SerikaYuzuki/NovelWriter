import Foundation

extension AuthVaultRecord {
    /// Marks an exchange whose server result is indeterminate. Keeping this
    /// state in the journal lets cold-start recovery clear stale native
    /// operations without destroying the exact replay lane.
    public mutating func markProviderExchangeIndeterminate(
        operationID: UUID,
        fingerprint: String
    ) throws {
        guard let index = operations.firstIndex(where: {
            $0.kind == .exchangeAppleNativeCredential &&
                $0.operationID == operationID &&
                $0.fingerprint == fingerprint &&
                $0.phase == .providerCallStarted
        }) else {
            throw AuthError.operationJournalConflict
        }
        let existing = operations[index]
        operations[index] = AuthOperationJournalEntry(
            kind: existing.kind,
            operationID: existing.operationID,
            fingerprint: existing.fingerprint,
            requestDigest: existing.requestDigest,
            phase: .providerExchangeIndeterminate
        )
    }

    /// Drops only non-replayable interrupted exchange work. An indeterminate
    /// provider exchange is an exact-replay lane and must survive.
    public mutating func discardInterruptedAppleExchange() {
        operations.removeAll {
            $0.kind == .exchangeAppleNativeCredential &&
                $0.phase != .providerExchangeIndeterminate
        }
    }

    /// Atomically retires stale challenge and ordinary exchange work before a
    /// fresh native Apple flow. Session, refresh, and revoke state is intact.
    public mutating func beginFreshAppleAuthentication() {
        operations.removeAll { operation in
            switch operation.kind {
            case .createChallenge:
                return true
            case .exchangeAppleNativeCredential:
                return operation.phase != .providerExchangeIndeterminate
            case .revokeCurrentSession:
                return false
            }
        }
    }
}

extension InMemoryAuthSessionVault {
    public func markProviderExchangeIndeterminate(operationID: UUID, fingerprint: String) async throws {
        try record.markProviderExchangeIndeterminate(operationID: operationID, fingerprint: fingerprint)
    }

    public func beginFreshAppleAuthentication() async throws {
        record.beginFreshAppleAuthentication()
    }
}
