import Foundation

public enum AuthProvider: String, Codable, Hashable, Sendable { case apple }

public enum AuthClientPlatform: String, Codable, Hashable, Sendable { case ios, ipados, macos }

public struct AuthClientConfiguration: Equatable, Sendable {
    public let origin: URL
    public let clientVersion: String
    public let clientPlatform: AuthClientPlatform

    public init(origin: URL, clientVersion: String, clientPlatform: AuthClientPlatform) throws {
        guard origin.scheme?.lowercased() == "https", origin.host != nil,
              origin.path.isEmpty || origin.path == "/",
              origin.user == nil, origin.password == nil, origin.query == nil,
              origin.fragment == nil else { throw AuthError.invalidProductionOrigin }
        guard clientVersion.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#, options: .regularExpression) != nil else {
            throw AuthError.invalidClientVersion
        }
        self.origin = origin
        self.clientVersion = clientVersion
        self.clientPlatform = clientPlatform
    }
}

public struct AuthReceipt: Codable, Hashable, Sendable {
    public let commandKind: String
    public let operationID: UUID
    public let replayUntil: Date
    public init(commandKind: String, operationID: UUID, replayUntil: Date) {
        self.commandKind = commandKind; self.operationID = operationID; self.replayUntil = replayUntil
    }

    private enum CodingKeys: String, CodingKey { case commandKind, operationID = "operationId", replayUntil }
}

public struct RefreshRotationReceipt: Codable, Hashable, Sendable {
    public let commandKind: String
    public let rotationID: UUID
    public let replayUntil: Date
    public init(commandKind: String, rotationID: UUID, replayUntil: Date) {
        self.commandKind = commandKind; self.rotationID = rotationID; self.replayUntil = replayUntil
    }

    private enum CodingKeys: String, CodingKey { case commandKind, rotationID = "rotationId", replayUntil }
}

public struct AuthSessionBinding: Codable, Hashable, Sendable {
    public let serverInstanceID: UUID
    public let syncProtocolEpoch: UInt64
    public let accountID: String
    public let accountAuthEpoch: UInt64
    public let accountFence: String
    public let sessionID: UUID
    public init(serverInstanceID: UUID, syncProtocolEpoch: UInt64, accountID: String, accountAuthEpoch: UInt64, accountFence: String, sessionID: UUID) {
        self.serverInstanceID = serverInstanceID; self.syncProtocolEpoch = syncProtocolEpoch; self.accountID = accountID
        self.accountAuthEpoch = accountAuthEpoch; self.accountFence = accountFence; self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case serverInstanceID = "serverInstanceId", syncProtocolEpoch, accountID = "accountId", accountAuthEpoch, accountFence, sessionID = "sessionId"
    }
}

public struct AuthSessionTokens: Codable, Hashable, Sendable {
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshToken: String
    public let refreshTokenExpiresAt: Date
    public let refreshGeneration: UInt64
    public let tokenType: String
    public init(accessToken: String, accessTokenExpiresAt: Date, refreshToken: String, refreshTokenExpiresAt: Date, refreshGeneration: UInt64, tokenType: String = "Bearer") {
        self.accessToken = accessToken; self.accessTokenExpiresAt = accessTokenExpiresAt; self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt; self.refreshGeneration = refreshGeneration; self.tokenType = tokenType
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, accessTokenExpiresAt, refreshToken, refreshTokenExpiresAt, refreshGeneration, tokenType
    }
}

/// The nested binding/tokens/receipt wire shape is the only persisted model.
public struct FuminiwaSession: Codable, Hashable, Sendable {
    public let binding: AuthSessionBinding
    public let tokens: AuthSessionTokens
    public let receipt: AuthReceipt
    public let rotationReceipt: RefreshRotationReceipt?
    public init(binding: AuthSessionBinding, tokens: AuthSessionTokens, receipt: AuthReceipt, rotationReceipt: RefreshRotationReceipt? = nil) {
        self.binding = binding; self.tokens = tokens; self.receipt = receipt; self.rotationReceipt = rotationReceipt
    }

    public var serverInstanceID: UUID {
        binding.serverInstanceID
    }

    public var syncProtocolEpoch: UInt64 {
        binding.syncProtocolEpoch
    }

    public var accountID: String {
        binding.accountID
    }

    public var accountAuthEpoch: UInt64 {
        binding.accountAuthEpoch
    }

    public var accountFence: String {
        binding.accountFence
    }

    public var sessionID: UUID {
        binding.sessionID
    }

    public var accessToken: String {
        tokens.accessToken
    }

    public var accessTokenExpiresAt: Date {
        tokens.accessTokenExpiresAt
    }

    public var refreshToken: String {
        tokens.refreshToken
    }

    public var refreshTokenExpiresAt: Date {
        tokens.refreshTokenExpiresAt
    }

    public var refreshGeneration: UInt64 {
        tokens.refreshGeneration
    }
}

public struct AuthChallenge: Codable, Hashable, Sendable {
    public let challengeID: UUID
    public let expiresAt: Date
    public let provider: AuthProvider
    public let flow: String
    public let audience: String
    public let providerConfigurationID: String
    public let requestedScopes: [String]
    public let state: String
    public let nonce: String
    public let receipt: AuthReceipt
    public init(
        challengeID: UUID,
        expiresAt: Date,
        provider: AuthProvider = .apple,
        flow: String = "native",
        audience: String,
        providerConfigurationID: String,
        requestedScopes: [String] = [],
        state: String,
        nonce: String,
        receipt: AuthReceipt
    ) {
        self.challengeID = challengeID; self.expiresAt = expiresAt; self.provider = provider; self.flow = flow; self.audience = audience
        self.providerConfigurationID = providerConfigurationID; self.requestedScopes = requestedScopes; self.state = state; self.nonce = nonce; self.receipt = receipt
    }

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challengeId", expiresAt, provider, flow, audience, providerConfigurationID = "providerConfigurationId", requestedScopes, state, nonce, receipt
    }
}

public enum AuthError: Error, Equatable, Sendable {
    case missingSession, invalidProvider, challengeExpired, stateMismatch, providerRejected, refreshRejected, staleResponse
    case invalidProductionOrigin, invalidClientVersion, invalidWireResponse, invalidCredentialEncoding, missingNoStore, invalidMediaType, duplicateRotation
    case invalidCanonicalResponse, invalidResponseSemantics, restartAuthentication, authorizationInProgress
    case operationJournalConflict, staleSession
    case remote(AuthRemoteError)
}

public extension AuthError {
    /// Stable, content-free diagnostic token for app logs. Remote errors are
    /// reduced to the server's closed error code; credentials and request
    /// bodies never cross this boundary.
    var diagnosticToken: String {
        if case let .remote(remote) = self {
            return "AuthError.remote(\(remote.code))"
        }
        return "AuthError.\(String(describing: self))"
    }
}

/// A content-free diagnostic for failures that occur before an HTTP response
/// exists.  In particular, URLSession errors may contain a request URL or
/// localized text with credentials; neither is suitable for device logs.
public enum AuthNetworkDiagnostic {
    public static func token(for error: any Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        return "NSURLError(code=\(nsError.code))"
    }
}

public enum AuthRecoveryAction: String, Codable, Hashable, Sendable {
    case correctRequest
    case interactiveAppleSignIn
    case none
    case refreshFuminiwaSession
    case retrySameRequestAfterBackoff
    case updateClient
}

public enum AuthRetryability: String, Codable, Hashable, Sendable {
    case afterBackoff
    case afterClientUpgrade
    case afterInteractiveAuthentication
    case afterTokenRefresh
    case never
}

/// A canonical, closed auth error returned by the server. The raw Apple
/// credential is never part of this value or any persisted operation journal.
public struct AuthRemoteError: Error, Codable, Equatable, Hashable, Sendable {
    public let code: String
    public let recoveryAction: AuthRecoveryAction
    public let retryability: AuthRetryability
    public let requestID: UUID
    public let operationID: UUID?
    public let challengeID: UUID?
    public let rotationID: UUID?
    public let retryAfterSeconds: UInt64?
    public let minimumClientVersion: String?
    public let maxCanonicalCommandBytes: UInt64?

    public init(
        code: String,
        recoveryAction: AuthRecoveryAction,
        retryability: AuthRetryability,
        requestID: UUID,
        operationID: UUID? = nil,
        challengeID: UUID? = nil,
        rotationID: UUID? = nil,
        retryAfterSeconds: UInt64? = nil,
        minimumClientVersion: String? = nil,
        maxCanonicalCommandBytes: UInt64? = nil
    ) {
        self.code = code
        self.recoveryAction = recoveryAction
        self.retryability = retryability
        self.requestID = requestID
        self.operationID = operationID
        self.challengeID = challengeID
        self.rotationID = rotationID
        self.retryAfterSeconds = retryAfterSeconds
        self.minimumClientVersion = minimumClientVersion
        self.maxCanonicalCommandBytes = maxCanonicalCommandBytes
    }
}

public enum AuthOperationKind: String, Codable, Hashable, Sendable {
    case createChallenge
    case exchangeAppleNativeCredential
    case revokeCurrentSession
}

public enum AuthOperationPhase: String, Codable, Hashable, Sendable {
    case reserved
    case providerCallStarted
    /// The server may have consumed Apple's one-use credential while the
    /// response was lost. This exact request is the only exchange lane that
    /// may survive an explicit fresh interactive flow.
    case providerExchangeIndeterminate
}

/// Non-secret operation metadata which may survive a process restart. Raw
/// Apple credentials are deliberately absent from this type.
public struct AuthOperationJournalEntry: Codable, Hashable, Sendable {
    public let kind: AuthOperationKind
    public let operationID: UUID
    public let fingerprint: String
    /// Digest of the exact canonical request, when the operation has one.
    /// This is never a credential or a replayable payload.
    public let requestDigest: Data?
    public let phase: AuthOperationPhase

    public init(
        kind: AuthOperationKind,
        operationID: UUID,
        fingerprint: String,
        requestDigest: Data? = nil,
        phase: AuthOperationPhase = .reserved
    ) {
        self.kind = kind
        self.operationID = operationID
        self.fingerprint = fingerprint
        self.requestDigest = requestDigest
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case kind, operationID = "operationId", fingerprint, requestDigest, phase
    }
}

/// A revoke request whose response may have been lost. It is intentionally
/// separate from the active session: local UI remains signed out while the
/// refresh credential is retained only to replay this exact revoke command.
public struct AuthPendingRevoke: Codable, Hashable, Sendable {
    public let session: FuminiwaSession
    public let operationID: UUID
    public let expiresAt: Date
    public let requestFingerprint: String
    public let canonicalRequest: Data
    public let requestDigest: Data

    public init(
        session: FuminiwaSession,
        operationID: UUID,
        expiresAt: Date,
        requestFingerprint: String,
        canonicalRequest: Data,
        requestDigest: Data
    ) {
        self.session = session
        self.operationID = operationID
        self.expiresAt = expiresAt
        self.requestFingerprint = requestFingerprint
        self.canonicalRequest = canonicalRequest
        self.requestDigest = requestDigest
    }
}

/// Keychain persistence is backed by this pure state machine. Keeping the
/// transition rules here makes restart and CAS behavior testable without the
/// Security framework.
public struct AuthVaultRecord: Codable, Hashable, Sendable {
    public var session: FuminiwaSession?
    public var pendingRotationID: UUID?
    public var operations: [AuthOperationJournalEntry]
    public var pendingRevoke: AuthPendingRevoke?

    public init(
        session: FuminiwaSession? = nil,
        pendingRotationID: UUID? = nil,
        operations: [AuthOperationJournalEntry] = [],
        pendingRevoke: AuthPendingRevoke? = nil
    ) {
        self.session = session
        self.pendingRotationID = pendingRotationID
        self.operations = operations
        self.pendingRevoke = pendingRevoke
    }

    public mutating func save(_ newSession: FuminiwaSession) {
        let sameSession = session?.sessionID == newSession.sessionID && session?.binding == newSession.binding
        session = newSession
        if !sameSession {
            pendingRotationID = nil
            operations.removeAll { operation in
                guard let pendingRevoke else { return true }
                return operation.operationID != pendingRevoke.operationID || operation.kind != .revokeCurrentSession
            }
        }
    }

    public mutating func loadOrReserveRevokeOperation(
        proposed: UUID,
        for expectedSession: FuminiwaSession,
        now: Date,
        receiptLifetimeSeconds: UInt64
    ) throws -> AuthPendingRevoke {
        guard (86400 ... 31_536_000).contains(receiptLifetimeSeconds) else { throw AuthError.invalidResponseSemantics }
        if let pendingRevoke {
            if pendingRevoke.expiresAt <= now {
                self.pendingRevoke = nil
                operations.removeAll { $0.operationID == pendingRevoke.operationID }
            } else {
                guard pendingRevoke.session.binding == expectedSession.binding else { throw AuthError.staleSession }
                return pendingRevoke
            }
        }
        guard session?.binding == expectedSession.binding else { throw AuthError.staleSession }
        let fingerprint = "revoke:\(expectedSession.sessionID.uuidString.lowercased())"
        let operation = try loadOrReserveOperation(kind: .revokeCurrentSession, proposed: proposed, fingerprint: fingerprint)
        _ = try beginOperation(kind: operation.kind, operationID: operation.operationID, fingerprint: fingerprint)
        let command = AuthJCS.object([
            ("operationId", operation.operationID.uuidString.lowercased()),
            ("scope", "currentSession")
        ])
        let pending = AuthPendingRevoke(
            session: expectedSession,
            operationID: operation.operationID,
            expiresAt: now.addingTimeInterval(TimeInterval(receiptLifetimeSeconds)),
            requestFingerprint: fingerprint,
            canonicalRequest: command.bytes,
            requestDigest: command.sha256
        )
        pendingRevoke = pending
        session = nil
        pendingRotationID = nil
        operations.removeAll { operation in
            operation.kind != .revokeCurrentSession || operation.operationID != pending.operationID
        }
        return pending
    }

    public mutating func clearPendingRevoke(operationID: UUID) {
        guard pendingRevoke?.operationID == operationID else { return }
        pendingRevoke = nil
        operations.removeAll { $0.kind == .revokeCurrentSession && $0.operationID == operationID }
    }

    public mutating func removeLocalSession() {
        session = nil
        pendingRotationID = nil
        operations.removeAll { operation in
            guard let pendingRevoke else { return true }
            return operation.operationID != pendingRevoke.operationID || operation.kind != .revokeCurrentSession
        }
    }

    public mutating func loadOrReserveRefreshRotation(proposed: UUID, for expectedSession: FuminiwaSession) throws -> UUID {
        guard session == expectedSession else { throw AuthError.staleSession }
        if let pendingRotationID {
            return pendingRotationID
        }
        pendingRotationID = proposed
        return proposed
    }

    public mutating func compareAndSwap(
        expectedRefreshToken: String,
        expectedGeneration: UInt64,
        rotationID: UUID,
        replacing newSession: FuminiwaSession
    ) -> Bool {
        guard let current = session,
              current.refreshToken == expectedRefreshToken,
              current.refreshGeneration == expectedGeneration,
              pendingRotationID == rotationID,
              newSession.binding == current.binding else { return false }
        session = newSession
        pendingRotationID = nil
        return true
    }

    public mutating func loadOrReserveOperation(kind: AuthOperationKind, proposed: UUID, fingerprint: String) throws -> AuthOperationJournalEntry {
        if kind == .exchangeAppleNativeCredential,
           let activeExchange = operations.first(where: { $0.kind == kind }),
           activeExchange.fingerprint != fingerprint,
           activeExchange.phase != .providerExchangeIndeterminate {
            throw AuthError.operationJournalConflict
        }
        if let existing = operations.first(where: { $0.kind == kind && $0.fingerprint == fingerprint }) {
            return existing
        }
        guard !operations.contains(where: { $0.operationID == proposed }),
              pendingRotationID != proposed,
              pendingRevoke?.operationID != proposed else {
            throw AuthError.operationJournalConflict
        }
        let entry = AuthOperationJournalEntry(kind: kind, operationID: proposed, fingerprint: fingerprint)
        operations.append(entry)
        return entry
    }

    public mutating func beginOperation(kind: AuthOperationKind, operationID: UUID, fingerprint: String) throws -> AuthOperationJournalEntry {
        guard let index = operations.firstIndex(where: { $0.kind == kind && $0.operationID == operationID && $0.fingerprint == fingerprint }) else {
            throw AuthError.operationJournalConflict
        }
        let existing = operations[index]
        if existing.phase == .providerCallStarted {
            return existing
        }
        let started = AuthOperationJournalEntry(
            kind: existing.kind,
            operationID: existing.operationID,
            fingerprint: existing.fingerprint,
            requestDigest: existing.requestDigest,
            phase: .providerCallStarted
        )
        operations[index] = started
        return started
    }

    /// Commits a provider response only while the exact journal owner is
    /// still in its provider-call phase. Sign-out and a later operation remove
    /// or replace this entry, so a delayed response cannot install a session
    /// into a newer auth scope.
    public mutating func commitOperationSession(
        kind: AuthOperationKind,
        operationID: UUID,
        fingerprint: String,
        session: FuminiwaSession
    ) -> Bool {
        guard let index = operations.firstIndex(where: {
            $0.kind == kind &&
                $0.operationID == operationID &&
                $0.fingerprint == fingerprint &&
                $0.phase == .providerCallStarted
        }) else {
            return false
        }
        // Keep the exact lookup above as an ownership proof. `save` then
        // performs the normal session replacement and journal cleanup.
        operations.remove(at: index)
        save(session)
        return true
    }

    public mutating func clearOperation(kind: AuthOperationKind, operationID: UUID) {
        operations.removeAll { $0.kind == kind && $0.operationID == operationID }
    }

    public mutating func clearOperation(kind: AuthOperationKind, fingerprint: String) {
        operations.removeAll { $0.kind == kind && $0.fingerprint == fingerprint }
    }

    public mutating func rollForwardExpiredRevokeOperation(
        proposed: UUID,
        now: Date,
        receiptLifetimeSeconds: UInt64
    ) throws -> AuthPendingRevoke {
        try rollForwardExpiredRevokeOperation(
            proposed: proposed,
            now: now,
            receiptLifetimeSeconds: receiptLifetimeSeconds,
            preservingSession: false
        )
    }

    /// Rolls the exact parked revoke forward without touching an active
    /// session that may have been saved after the original sign-out.
    public mutating func rollForwardExpiredRevokeOperationPreservingSession(
        proposed: UUID,
        now: Date,
        receiptLifetimeSeconds: UInt64
    ) throws -> AuthPendingRevoke {
        try rollForwardExpiredRevokeOperation(
            proposed: proposed,
            now: now,
            receiptLifetimeSeconds: receiptLifetimeSeconds,
            preservingSession: true
        )
    }

    private mutating func rollForwardExpiredRevokeOperation(
        proposed: UUID,
        now: Date,
        receiptLifetimeSeconds: UInt64,
        preservingSession: Bool
    ) throws -> AuthPendingRevoke {
        guard let pendingRevoke, pendingRevoke.expiresAt <= now else {
            throw AuthError.staleSession
        }
        self.pendingRevoke = nil
        operations.removeAll { $0.operationID == pendingRevoke.operationID }
        let fingerprint = pendingRevoke.requestFingerprint
        let operation = try loadOrReserveOperation(
            kind: .revokeCurrentSession,
            proposed: proposed,
            fingerprint: fingerprint
        )
        _ = try beginOperation(kind: operation.kind, operationID: operation.operationID, fingerprint: fingerprint)
        let command = AuthJCS.object([
            ("operationId", operation.operationID.uuidString.lowercased()),
            ("scope", "currentSession")
        ])
        let rolled = AuthPendingRevoke(
            session: pendingRevoke.session,
            operationID: operation.operationID,
            expiresAt: now.addingTimeInterval(TimeInterval(receiptLifetimeSeconds)),
            requestFingerprint: fingerprint,
            canonicalRequest: command.bytes,
            requestDigest: command.sha256
        )
        self.pendingRevoke = rolled
        if !preservingSession {
            session = nil
            pendingRotationID = nil
        }
        return rolled
    }

    public mutating func bindOperationRequest(
        kind: AuthOperationKind,
        operationID: UUID,
        fingerprint: String,
        requestDigest: Data
    ) throws -> AuthOperationJournalEntry {
        guard let index = operations.firstIndex(where: {
            $0.kind == kind && $0.operationID == operationID && $0.fingerprint == fingerprint
        }) else {
            throw AuthError.operationJournalConflict
        }
        let existing = operations[index]
        if let existingDigest = existing.requestDigest, existingDigest != requestDigest {
            throw AuthError.operationJournalConflict
        }
        let bound = AuthOperationJournalEntry(
            kind: existing.kind,
            operationID: existing.operationID,
            fingerprint: existing.fingerprint,
            requestDigest: requestDigest,
            phase: existing.phase
        )
        operations[index] = bound
        return bound
    }
}

public protocol FuminiwaAuthTransport: Sendable {
    func createAppleChallenge(clientPlatform: AuthClientPlatform, operationID: UUID) async throws -> AuthChallenge
    func exchangeApple(challenge: AuthChallenge, authorizationCode: Data, identityToken: Data, operationID: UUID) async throws -> FuminiwaSession
    func refresh(session: FuminiwaSession, rotationID: UUID) async throws -> FuminiwaSession
    func revoke(pending: AuthPendingRevoke) async throws
}

public protocol AuthSessionVault: Sendable {
    func load() async throws -> FuminiwaSession?
    func save(_ session: FuminiwaSession) async throws
    func remove() async throws
    func loadOrReserveRefreshRotation(proposed: UUID, for session: FuminiwaSession) async throws -> UUID
    func compareAndSwap(expectedRefreshToken: String, expectedGeneration: UInt64, rotationID: UUID, replacing session: FuminiwaSession) async throws -> Bool
    func loadOrReserveOperation(kind: AuthOperationKind, proposed: UUID, fingerprint: String) async throws -> AuthOperationJournalEntry
    func beginOperation(kind: AuthOperationKind, operationID: UUID, fingerprint: String) async throws -> AuthOperationJournalEntry
    func commitOperationSession(
        kind: AuthOperationKind,
        operationID: UUID,
        fingerprint: String,
        session: FuminiwaSession
    ) async throws -> Bool
    func clearOperation(kind: AuthOperationKind, operationID: UUID) async throws
    func clearOperation(kind: AuthOperationKind, fingerprint: String) async throws
    func discardInterruptedAppleExchange() async throws
    func markProviderExchangeIndeterminate(operationID: UUID, fingerprint: String) async throws
    func beginFreshAppleAuthentication() async throws
    func bindOperationRequest(kind: AuthOperationKind, operationID: UUID, fingerprint: String, requestDigest: Data) async throws -> AuthOperationJournalEntry
    func loadPendingRevoke() async throws -> AuthPendingRevoke?
    func loadOrReserveRevokeOperation(proposed: UUID, for session: FuminiwaSession, now: Date, receiptLifetimeSeconds: UInt64) async throws -> AuthPendingRevoke
    func rollForwardExpiredRevokeOperation(proposed: UUID, now: Date, receiptLifetimeSeconds: UInt64) async throws -> AuthPendingRevoke
    func rollForwardExpiredRevokeOperationPreservingSession(proposed: UUID, now: Date, receiptLifetimeSeconds: UInt64) async throws -> AuthPendingRevoke
    func clearPendingRevoke(operationID: UUID) async throws
}

public actor InMemoryAuthSessionVault: AuthSessionVault {
    var record: AuthVaultRecord

    public init(session: FuminiwaSession? = nil) {
        record = AuthVaultRecord(session: session)
    }

    public init(record: AuthVaultRecord) {
        self.record = record
    }

    public func load() async throws -> FuminiwaSession? {
        record.session
    }

    public func save(_ session: FuminiwaSession) async throws {
        record.save(session)
    }

    public func remove() async throws {
        record.removeLocalSession()
    }

    public func loadOrReserveRefreshRotation(proposed: UUID, for session: FuminiwaSession) async throws -> UUID {
        try record.loadOrReserveRefreshRotation(proposed: proposed, for: session)
    }

    public func compareAndSwap(expectedRefreshToken: String, expectedGeneration: UInt64, rotationID: UUID, replacing session: FuminiwaSession) async throws -> Bool {
        record.compareAndSwap(expectedRefreshToken: expectedRefreshToken, expectedGeneration: expectedGeneration, rotationID: rotationID, replacing: session)
    }

    public func loadOrReserveOperation(kind: AuthOperationKind, proposed: UUID, fingerprint: String) async throws -> AuthOperationJournalEntry {
        try record.loadOrReserveOperation(kind: kind, proposed: proposed, fingerprint: fingerprint)
    }

    public func beginOperation(kind: AuthOperationKind, operationID: UUID, fingerprint: String) async throws -> AuthOperationJournalEntry {
        try record.beginOperation(kind: kind, operationID: operationID, fingerprint: fingerprint)
    }

    public func commitOperationSession(
        kind: AuthOperationKind,
        operationID: UUID,
        fingerprint: String,
        session: FuminiwaSession
    ) async throws -> Bool {
        record.commitOperationSession(
            kind: kind,
            operationID: operationID,
            fingerprint: fingerprint,
            session: session
        )
    }

    public func clearOperation(kind: AuthOperationKind, operationID: UUID) async throws {
        record.clearOperation(kind: kind, operationID: operationID)
    }

    public func clearOperation(kind: AuthOperationKind, fingerprint: String) async throws {
        record.clearOperation(kind: kind, fingerprint: fingerprint)
    }

    public func discardInterruptedAppleExchange() async throws {
        record.discardInterruptedAppleExchange()
    }

    public func bindOperationRequest(kind: AuthOperationKind, operationID: UUID, fingerprint: String, requestDigest: Data) async throws -> AuthOperationJournalEntry {
        try record.bindOperationRequest(kind: kind, operationID: operationID, fingerprint: fingerprint, requestDigest: requestDigest)
    }

    public func loadPendingRevoke() async throws -> AuthPendingRevoke? {
        record.pendingRevoke
    }

    public func loadOrReserveRevokeOperation(proposed: UUID, for session: FuminiwaSession, now: Date, receiptLifetimeSeconds: UInt64) async throws -> AuthPendingRevoke {
        try record.loadOrReserveRevokeOperation(proposed: proposed, for: session, now: now, receiptLifetimeSeconds: receiptLifetimeSeconds)
    }

    public func rollForwardExpiredRevokeOperation(proposed: UUID, now: Date, receiptLifetimeSeconds: UInt64) async throws -> AuthPendingRevoke {
        try record.rollForwardExpiredRevokeOperation(proposed: proposed, now: now, receiptLifetimeSeconds: receiptLifetimeSeconds)
    }

    public func rollForwardExpiredRevokeOperationPreservingSession(proposed: UUID, now: Date, receiptLifetimeSeconds: UInt64) async throws -> AuthPendingRevoke {
        try record.rollForwardExpiredRevokeOperationPreservingSession(
            proposed: proposed,
            now: now,
            receiptLifetimeSeconds: receiptLifetimeSeconds
        )
    }

    public func clearPendingRevoke(operationID: UUID) async throws {
        record.clearPendingRevoke(operationID: operationID)
    }

    public func snapshot() -> AuthVaultRecord {
        record
    }
}
