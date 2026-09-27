import Foundation
import NovelAuth
import NovelAuthApple
import Testing

@Suite("Apple authentication orchestration")
struct AppleAuthenticationOrchestratorTests {
    @Test("credential-state handle is committed only after server exchange succeeds")
    @MainActor
    func handleCommitAfterSuccess() async throws {
        let transport = OrchestratorTransport()
        let auth = try AuthSessionCoordinator(
            transport: transport,
            vault: InMemoryAuthSessionVault(),
            authLimits: limits()
        )
        let handles = InMemoryAppleCredentialStateHandleVault()
        let orchestrator = AppleAuthenticationOrchestrator(
            authSessionCoordinator: auth,
            authorizationProvider: StubAuthorizationProvider(),
            credentialStateHandleVault: handles,
            credentialStateProvider: StubCredentialStateProvider()
        )

        _ = try await orchestrator.signIn()
        #expect(try await handles.load(providerConfigurationID: "apple-primary-fuminiwa-v1") == "apple-user-handle")
    }

    @Test("failed server exchange does not commit a provider handle")
    @MainActor
    func noHandleOnFailure() async throws {
        let transport = OrchestratorTransport()
        await transport.failExchange()
        let auth = try AuthSessionCoordinator(
            transport: transport,
            vault: InMemoryAuthSessionVault(),
            authLimits: limits()
        )
        let handles = InMemoryAppleCredentialStateHandleVault()
        let orchestrator = AppleAuthenticationOrchestrator(
            authSessionCoordinator: auth,
            authorizationProvider: StubAuthorizationProvider(),
            credentialStateHandleVault: handles,
            credentialStateProvider: StubCredentialStateProvider()
        )

        await #expect(throws: Error.self) {
            _ = try await orchestrator.signIn()
        }
        #expect(try await handles.load(providerConfigurationID: "apple-primary-fuminiwa-v1") == nil)
    }

    @Test("phase observer reports only successful, content-free boundaries")
    @MainActor
    func phaseObserverOrderingAndRedaction() async throws {
        let successPhases = PhaseCollector()
        let successAuth = try AuthSessionCoordinator(
            transport: OrchestratorTransport(),
            vault: InMemoryAuthSessionVault(),
            authLimits: limits()
        )
        let successOrchestrator = AppleAuthenticationOrchestrator(
            authSessionCoordinator: successAuth,
            authorizationProvider: StubAuthorizationProvider(),
            credentialStateHandleVault: InMemoryAppleCredentialStateHandleVault(),
            credentialStateProvider: StubCredentialStateProvider(),
            phaseObserver: { phase in
                successPhases.append(phase)
            }
        )

        _ = try await successOrchestrator.signIn()
        #expect(successPhases.values() == [
            .challengeCreated,
            .nativeAuthorized,
            .serverExchanged
        ])
        #expect(
            successPhases.values().allSatisfy { phase in
                phase.rawValue == "challenge-created"
                    || phase.rawValue == "native-authorized"
                    || phase.rawValue == "server-exchanged"
            }
        )

        let failureTransport = OrchestratorTransport()
        await failureTransport.failExchange()
        let failurePhases = PhaseCollector()
        let failureAuth = try AuthSessionCoordinator(
            transport: failureTransport,
            vault: InMemoryAuthSessionVault(),
            authLimits: limits()
        )
        let failureOrchestrator = AppleAuthenticationOrchestrator(
            authSessionCoordinator: failureAuth,
            authorizationProvider: StubAuthorizationProvider(),
            credentialStateHandleVault: InMemoryAppleCredentialStateHandleVault(),
            credentialStateProvider: StubCredentialStateProvider(),
            phaseObserver: { phase in
                failurePhases.append(phase)
            }
        )

        await #expect(throws: Error.self) {
            _ = try await failureOrchestrator.signIn()
        }
        #expect(failurePhases.values() == [.challengeCreated, .nativeAuthorized])
    }

    @Test("revoked credential state removes only the provider handle")
    @MainActor
    func revokedHandleRemoval() async throws {
        let handles = InMemoryAppleCredentialStateHandleVault()
        try await handles.save("apple-user-handle", providerConfigurationID: "apple-primary-fuminiwa-v1")
        let state = StubCredentialStateProvider(state: .revoked)
        let auth = try AuthSessionCoordinator(
            transport: OrchestratorTransport(),
            vault: InMemoryAuthSessionVault(),
            authLimits: limits()
        )
        let orchestrator = AppleAuthenticationOrchestrator(
            authSessionCoordinator: auth,
            authorizationProvider: StubAuthorizationProvider(),
            credentialStateHandleVault: handles,
            credentialStateProvider: state
        )

        #expect(try await orchestrator.checkCredentialState() == .revoked)
        #expect(try await handles.load(providerConfigurationID: "apple-primary-fuminiwa-v1") == nil)
    }

    private func limits() throws -> AuthLimits {
        try AuthLimits(
            accessTokenLifetimeSeconds: 900,
            authReceiptLifetimeSeconds: 7_776_000,
            challengeLifetimeSeconds: 300,
            maxCanonicalCommandBytes: 65536,
            maxProviderClockSkewSeconds: 300,
            refreshTokenLifetimeSeconds: 7_776_000
        )
    }
}

@MainActor
private final class PhaseCollector {
    private var recorded: [AppleAuthenticationPhase] = []

    func append(_ phase: AppleAuthenticationPhase) {
        recorded.append(phase)
    }

    func values() -> [AppleAuthenticationPhase] {
        recorded
    }
}

@MainActor
private final class StubAuthorizationProvider: AppleAuthorizationProviding {
    func authorize(using _: AuthChallenge) async throws -> AppleAuthorizationPayload {
        AppleAuthorizationPayload(
            userHandle: "apple-user-handle",
            authorizationCode: Data("apple-code".utf8),
            identityToken: Data("header.payload.signature".utf8)
        )
    }
}

private actor StubCredentialStateProvider: AppleCredentialStateProviding {
    private let state: AppleCredentialState

    init(state: AppleCredentialState = .authorized) {
        self.state = state
    }

    func credentialState(for _: String) async throws -> AppleCredentialState {
        state
    }
}

private actor OrchestratorTransport: FuminiwaAuthTransport {
    private var exchangeFails = false

    func failExchange() {
        exchangeFails = true
    }

    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID: UUID) async throws -> AuthChallenge {
        AuthChallenge(
            challengeID: UUID(uuidString: "21000000-0000-4000-8000-000000000001") ?? UUID(),
            expiresAt: Date(timeIntervalSinceNow: 300),
            audience: "dev.serikayuzuki.fuminiwa",
            providerConfigurationID: "apple-primary-fuminiwa-v1",
            state: String(repeating: "A", count: 43),
            nonce: String(repeating: "B", count: 43),
            receipt: AuthReceipt(
                commandKind: "createChallenge",
                operationID: operationID,
                replayUntil: Date(timeIntervalSinceNow: 3600)
            )
        )
    }

    func exchangeApple(challenge _: AuthChallenge, authorizationCode _: Data, identityToken _: Data, operationID: UUID) async throws -> FuminiwaSession {
        if exchangeFails {
            throw AuthError.providerRejected
        }
        let binding = AuthSessionBinding(
            serverInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID(),
            syncProtocolEpoch: 2,
            accountID: "acct_AAAAAAAAAAAAAAAA",
            accountAuthEpoch: 1,
            accountFence: "fence_AAAAAAAAAAAAAAAAAAAA",
            sessionID: UUID(uuidString: "41000000-0000-4000-8000-000000000001") ?? UUID()
        )
        return FuminiwaSession(
            binding: binding,
            tokens: AuthSessionTokens(
                accessToken: "fma1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                accessTokenExpiresAt: Date(timeIntervalSinceNow: 900),
                refreshToken: "fmr1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                refreshTokenExpiresAt: Date(timeIntervalSinceNow: 7_776_000),
                refreshGeneration: 1
            ),
            receipt: AuthReceipt(
                commandKind: "exchangeAppleNativeCredential",
                operationID: operationID,
                replayUntil: Date(timeIntervalSinceNow: 7_776_000)
            )
        )
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        throw AuthError.providerRejected
    }
}
