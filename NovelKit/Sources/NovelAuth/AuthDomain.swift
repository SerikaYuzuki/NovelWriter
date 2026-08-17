import Foundation

public enum AuthProvider: String, Codable, Hashable, Sendable { case apple }

public enum AuthClientPlatform: String, Codable, Hashable, Sendable { case ios, ipados, macos }

public struct AuthClientConfiguration: Equatable, Sendable {
    public let origin: URL
    public let clientVersion: String
    public let clientPlatform: AuthClientPlatform

    public init(origin: URL, clientVersion: String, clientPlatform: AuthClientPlatform) throws {
        guard origin.scheme?.lowercased() == "https", origin.host != nil,
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
    public init(challengeID: UUID, expiresAt: Date, provider: AuthProvider = .apple, flow: String = "native", audience: String, providerConfigurationID: String, requestedScopes: [String] = [], state: String, nonce: String, receipt: AuthReceipt) {
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
}

public protocol FuminiwaAuthTransport: Sendable {
    func createAppleChallenge(clientPlatform: AuthClientPlatform, operationID: UUID) async throws -> AuthChallenge
    func exchangeApple(challenge: AuthChallenge, authorizationCode: Data, identityToken: Data, operationID: UUID) async throws -> FuminiwaSession
    func refresh(session: FuminiwaSession, rotationID: UUID) async throws -> FuminiwaSession
    func revoke(session: FuminiwaSession, operationID: UUID) async throws
}

public protocol AuthSessionVault: Sendable {
    func load() async throws -> FuminiwaSession?
    func save(_ session: FuminiwaSession) async throws
    func remove() async throws
    func reserveRefreshRotation(_ rotationID: UUID, for session: FuminiwaSession) async throws
    func compareAndSwap(expectedRefreshToken: String, expectedGeneration: UInt64, replacing session: FuminiwaSession) async throws -> Bool
}

public actor InMemoryAuthSessionVault: AuthSessionVault {
    private var session: FuminiwaSession?
    private var pendingRotations: Set<UUID> = []
    public init(session: FuminiwaSession? = nil) {
        self.session = session
    }

    public func load() async throws -> FuminiwaSession? {
        session
    }

    public func save(_ session: FuminiwaSession) async throws {
        self.session = session
    }

    public func remove() async throws {
        session = nil; pendingRotations.removeAll()
    }

    public func reserveRefreshRotation(_ rotationID: UUID, for session: FuminiwaSession) async throws {
        guard self.session == session else { throw AuthError.staleResponse }
        guard pendingRotations.insert(rotationID).inserted else { throw AuthError.duplicateRotation }
    }

    public func compareAndSwap(expectedRefreshToken: String, expectedGeneration: UInt64, replacing session: FuminiwaSession) async throws -> Bool {
        guard self.session?.refreshToken == expectedRefreshToken, self.session?.refreshGeneration == expectedGeneration else { return false }
        self.session = session; pendingRotations.removeAll(); return true
    }
}

public actor AuthSessionCoordinator {
    private let transport: any FuminiwaAuthTransport
    private let vault: any AuthSessionVault
    private let platform: AuthClientPlatform
    public init(transport: any FuminiwaAuthTransport, vault: any AuthSessionVault, platform: AuthClientPlatform = .macos) {
        self.transport = transport; self.vault = vault; self.platform = platform
    }

    public func currentSession() async throws -> FuminiwaSession? {
        try await vault.load()
    }

    public func createAppleChallenge() async throws -> AuthChallenge {
        try await transport.createAppleChallenge(clientPlatform: platform, operationID: UUID())
    }

    public func completeAppleSignIn(challenge: AuthChallenge, authorizationCode: Data, identityToken: Data, operationID: UUID = UUID()) async throws -> FuminiwaSession {
        let session = try await transport.exchangeApple(challenge: challenge, authorizationCode: authorizationCode, identityToken: identityToken, operationID: operationID)
        try await vault.save(session); return session
    }

    public func refresh() async throws -> FuminiwaSession {
        guard let current = try await vault.load() else { throw AuthError.missingSession }
        let rotationID = UUID(); try await vault.reserveRefreshRotation(rotationID, for: current)
        let refreshed = try await transport.refresh(session: current, rotationID: rotationID)
        guard refreshed.refreshGeneration == current.refreshGeneration + 1 else { throw AuthError.staleResponse }
        guard try await vault.compareAndSwap(expectedRefreshToken: current.refreshToken, expectedGeneration: current.refreshGeneration, replacing: refreshed) else { throw AuthError.staleResponse }
        return refreshed
    }

    public func signOut() async throws {
        guard let current = try await vault.load() else { return }
        try await transport.revoke(session: current, operationID: UUID()); try await vault.remove()
    }
}
