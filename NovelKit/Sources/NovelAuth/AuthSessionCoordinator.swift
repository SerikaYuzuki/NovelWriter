import Foundation

public actor AuthSessionCoordinator {
    private let transport: any FuminiwaAuthTransport
    private let vault: any AuthSessionVault
    private let platform: AuthClientPlatform
    private let authLimits: AuthLimits
    private let clock: @Sendable () -> Date
    public init(
        transport: any FuminiwaAuthTransport,
        vault: any AuthSessionVault,
        authLimits: AuthLimits,
        platform: AuthClientPlatform = .macos,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport; self.vault = vault; self.platform = platform
        self.authLimits = authLimits; self.clock = clock
    }

    public func currentSession() async throws -> FuminiwaSession? {
        try await vault.load()
    }

    public func createAppleChallenge(operationID proposedOperationID: UUID? = nil) async throws -> AuthChallenge {
        let proposed = proposedOperationID ?? UUID()
        let fingerprint = "apple-native:\(platform.rawValue)"
        let entry = try await vault.loadOrReserveOperation(kind: .createChallenge, proposed: proposed, fingerprint: fingerprint)
        if entry.phase == .reserved {
            _ = try await vault.beginOperation(kind: .createChallenge, operationID: entry.operationID, fingerprint: fingerprint)
        }
        do {
            let challenge = try await transport.createAppleChallenge(clientPlatform: platform, operationID: entry.operationID)
            try await vault.clearOperation(kind: .createChallenge, operationID: entry.operationID)
            return challenge
        } catch {
            throw error
        }
    }

    public func completeAppleSignIn(challenge: AuthChallenge, authorizationCode: Data, identityToken: Data, operationID: UUID = UUID()) async throws -> FuminiwaSession {
        let fingerprint = "apple-exchange:\(challenge.challengeID.uuidString.lowercased())"
        let reserved = try await vault.loadOrReserveOperation(kind: .exchangeAppleNativeCredential, proposed: operationID, fingerprint: fingerprint)
        guard reserved.operationID == operationID else {
            throw AuthError.operationJournalConflict
        }
        let request = try AuthCanonicalRequests.exchangeApple(
            challenge: challenge,
            authorizationCode: authorizationCode,
            identityToken: identityToken,
            operationID: reserved.operationID
        )
        _ = try await vault.bindOperationRequest(
            kind: reserved.kind,
            operationID: reserved.operationID,
            fingerprint: fingerprint,
            requestDigest: request.sha256
        )
        _ = try await vault.beginOperation(kind: .exchangeAppleNativeCredential, operationID: reserved.operationID, fingerprint: fingerprint)
        let session: FuminiwaSession
        do {
            session = try await transport.exchangeApple(challenge: challenge, authorizationCode: authorizationCode, identityToken: identityToken, operationID: reserved.operationID)
        } catch let error as AuthError {
            if case let .remote(remote) = error,
               remote.recoveryAction == .interactiveAppleSignIn {
                throw AuthError.restartAuthentication
            }
            throw error
        } catch {
            throw error
        }
        guard try await vault.commitOperationSession(
            kind: .exchangeAppleNativeCredential,
            operationID: reserved.operationID,
            fingerprint: fingerprint,
            session: session
        ) else {
            throw AuthError.staleResponse
        }
        return session
    }

    /// Explicitly abandons an interrupted exchange after a process restart.
    /// Credentials are never recovered from the journal; the caller must start
    /// a fresh Apple authorization flow afterward.
    public func discardInterruptedAppleExchange(challengeID: UUID) async throws {
        let fingerprint = "apple-exchange:\(challengeID.uuidString.lowercased())"
        try await vault.clearOperation(kind: .exchangeAppleNativeCredential, fingerprint: fingerprint)
    }

    public func refresh() async throws -> FuminiwaSession {
        guard let current = try await vault.load() else { throw AuthError.missingSession }
        let rotationID = try await vault.loadOrReserveRefreshRotation(proposed: UUID(), for: current)
        let refreshed = try await transport.refresh(session: current, rotationID: rotationID)
        guard refreshed.refreshGeneration == current.refreshGeneration + 1 else { throw AuthError.staleResponse }
        guard try await vault.compareAndSwap(
            expectedRefreshToken: current.refreshToken,
            expectedGeneration: current.refreshGeneration,
            rotationID: rotationID,
            replacing: refreshed
        ) else { throw AuthError.staleResponse }
        return refreshed
    }

    /// Replays only the durable revoke operation left by an earlier sign-out.
    ///
    /// This is deliberately separate from `signOut()`: a new session may have
    /// been saved while the old revoke was offline, and replaying the old
    /// operation must never recursively sign out that newer session.
    public func resumePendingRevoke() async throws {
        guard let saved = try await vault.loadPendingRevoke() else { return }
        let pending = if saved.expiresAt <= clock() {
            try await vault.rollForwardExpiredRevokeOperationPreservingSession(
                proposed: UUID(),
                now: clock(),
                receiptLifetimeSeconds: authLimits.authReceiptLifetimeSeconds
            )
        } else {
            saved
        }
        do {
            try await transport.revoke(pending: pending)
            try await vault.clearPendingRevoke(operationID: pending.operationID)
        } catch let error as AuthError {
            if case let .remote(remote) = error, remote.code == "sessionRevoked" {
                try await vault.clearPendingRevoke(operationID: pending.operationID)
                return
            }
            throw error
        }
    }

    public func signOut() async throws {
        if let pending = try await vault.loadPendingRevoke() {
            if pending.expiresAt <= clock() {
                let rolled = try await vault.rollForwardExpiredRevokeOperation(
                    proposed: UUID(),
                    now: clock(),
                    receiptLifetimeSeconds: authLimits.authReceiptLifetimeSeconds
                )
                do {
                    try await transport.revoke(pending: rolled)
                    try await vault.clearPendingRevoke(operationID: rolled.operationID)
                    return
                } catch let error as AuthError {
                    if case let .remote(remote) = error, remote.code == "sessionRevoked" {
                        try await vault.clearPendingRevoke(operationID: rolled.operationID)
                        return
                    }
                    try await vault.remove()
                    throw error
                }
            } else {
                do {
                    try await transport.revoke(pending: pending)
                    try await vault.clearPendingRevoke(operationID: pending.operationID)
                    if try await vault.load() != nil {
                        try await signOut()
                    }
                    return
                } catch let error as AuthError {
                    if case let .remote(remote) = error, remote.code == "sessionRevoked" {
                        try await vault.clearPendingRevoke(operationID: pending.operationID)
                        return
                    }
                    try await vault.remove()
                    throw error
                }
            }
        }
        guard let current = try await vault.load() else { return }
        let pending = try await vault.loadOrReserveRevokeOperation(
            proposed: UUID(),
            for: current,
            now: clock(),
            receiptLifetimeSeconds: authLimits.authReceiptLifetimeSeconds
        )
        do {
            try await transport.revoke(pending: pending)
            try await vault.clearPendingRevoke(operationID: pending.operationID)
        } catch let error as AuthError {
            if case let .remote(remote) = error, remote.code == "sessionRevoked" {
                try await vault.clearPendingRevoke(operationID: pending.operationID)
                return
            }
            throw error
        } catch {
            // Active credentials were removed atomically when the pending
            // revoke was parked. Keep only the exact replay credential.
            throw error
        }
    }
}
