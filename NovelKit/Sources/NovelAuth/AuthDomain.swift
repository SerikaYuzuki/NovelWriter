import Foundation

/// Provider-neutral identity boundary. v1 exposes only `.apple` in UI, while
/// the rest of the sync stack accepts this shape without knowing OIDC claims.
public enum AuthProvider: String, Codable, Hashable, Sendable {
    case apple
}

public struct AuthChallenge: Codable, Hashable, Sendable {
    public let challengeID: UUID
    public let state: String
    public let nonce: String
    public let expiresAt: Date
    public let provider: AuthProvider
    public let flow: String

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challengeId"
        case state
        case nonce
        case expiresAt
        case provider
        case flow
    }

    public init(
        challengeID: UUID,
        state: String,
        nonce: String,
        expiresAt: Date,
        provider: AuthProvider = .apple,
        flow: String = "native"
    ) {
        self.challengeID = challengeID
        self.state = state
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.provider = provider
        self.flow = flow
    }
}

public struct FuminiwaSession: Codable, Hashable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let accountID: String
    public let accountAuthEpoch: UInt64
    public let accountFence: String
    public let refreshGeneration: UInt64

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case accountID = "accountId"
        case accountAuthEpoch
        case accountFence
        case refreshGeneration
    }

    public init(
        accessToken: String,
        refreshToken: String,
        accountID: String,
        accountAuthEpoch: UInt64,
        accountFence: String,
        refreshGeneration: UInt64
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.accountAuthEpoch = accountAuthEpoch
        self.accountFence = accountFence
        self.refreshGeneration = refreshGeneration
    }
}

public enum AuthError: Error, Equatable, Sendable {
    case missingSession
    case invalidProvider
    case challengeExpired
    case stateMismatch
    case providerRejected
    case refreshRejected
    case staleResponse
}

/// The HTTP implementation is deliberately injected. This keeps auth domain
/// tests offline and gives future providers the same exchange/refresh seam.
public protocol FuminiwaAuthTransport: Sendable {
    func createAppleChallenge() async throws -> AuthChallenge
    func exchangeApple(
        challenge: AuthChallenge,
        authorizationCode: Data,
        identityToken: Data,
        operationID: UUID
    ) async throws -> FuminiwaSession
    func refresh(session: FuminiwaSession, rotationID: UUID) async throws -> FuminiwaSession
    func revoke(session: FuminiwaSession) async throws
}

public protocol AuthSessionVault: Sendable {
    func load() async throws -> FuminiwaSession?
    func save(_ session: FuminiwaSession) async throws
    func remove() async throws
}

public actor InMemoryAuthSessionVault: AuthSessionVault {
    private var session: FuminiwaSession?

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
        session = nil
    }
}

/// Refresh responses can arrive after a newer rotation. The vault write is
/// guarded by generation and the currently-presented refresh token.
public actor AuthSessionCoordinator {
    private let transport: any FuminiwaAuthTransport
    private let vault: any AuthSessionVault

    public init(transport: any FuminiwaAuthTransport, vault: any AuthSessionVault) {
        self.transport = transport
        self.vault = vault
    }

    public func currentSession() async throws -> FuminiwaSession? {
        try await vault.load()
    }

    /// Starts the provider-neutral half of Sign in with Apple. The native
    /// AuthenticationServices adapter owns the presentation and returns only
    /// one-use Apple credentials; this actor never sees UI objects.
    public func createAppleChallenge() async throws -> AuthChallenge {
        try await transport.createAppleChallenge()
    }

    /// Completes an Apple exchange and persists the FUMINIWA session only
    /// after the server has issued it. Apple credentials are intentionally not
    /// written to the vault or returned from this method.
    public func completeAppleSignIn(
        challenge: AuthChallenge,
        authorizationCode: Data,
        identityToken: Data,
        operationID: UUID = UUID()
    ) async throws -> FuminiwaSession {
        let session = try await transport.exchangeApple(
            challenge: challenge,
            authorizationCode: authorizationCode,
            identityToken: identityToken,
            operationID: operationID
        )
        try await vault.save(session)
        return session
    }

    public func refresh() async throws -> FuminiwaSession {
        guard let current = try await vault.load() else {
            throw AuthError.missingSession
        }
        let rotationID = UUID()
        let refreshed = try await transport.refresh(session: current, rotationID: rotationID)
        guard refreshed.refreshGeneration > current.refreshGeneration else {
            throw AuthError.staleResponse
        }
        guard let stillCurrent = try await vault.load(),
              stillCurrent.refreshToken == current.refreshToken,
              stillCurrent.refreshGeneration == current.refreshGeneration else {
            // A concurrent newer response already won the vault CAS.
            throw AuthError.staleResponse
        }
        try await vault.save(refreshed)
        return refreshed
    }

    public func signOut() async throws {
        if let current = try await vault.load() {
            try? await transport.revoke(session: current)
        }
        try await vault.remove()
    }
}
