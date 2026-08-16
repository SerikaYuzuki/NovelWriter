import Foundation
import NovelAuth
import Testing

@Suite("Provider-neutral auth")
struct AuthDomainTests {
    @Test("test host composition disables the server lane before reading UserDefaults")
    func hostCompositionIsOffline() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "NovelAuthTests.runtime.\(UUID().uuidString)")
        )
        defaults.set("http://192.168.11.5:18080", forKey: FuminiwaRuntimeEnvironment.syncServerURLKey)

        let runtime = FuminiwaRuntimeEnvironment(
            userDefaults: defaults,
            environment: [FuminiwaRuntimeEnvironment.testNetworkDisabledKey: "1"]
        )

        #expect(runtime.networkPolicy == .disabled)
        #expect(runtime.syncServerURL == nil)
        #expect(!runtime.allowsNetwork)
    }

    @Test("production composition uses only the configured endpoint")
    func productionCompositionUsesConfiguredEndpoint() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "NovelAuthTests.runtime.\(UUID().uuidString)")
        )
        defaults.set("http://127.0.0.1:18080", forKey: FuminiwaRuntimeEnvironment.syncServerURLKey)

        let runtime = FuminiwaRuntimeEnvironment(userDefaults: defaults, environment: [:])

        #expect(runtime.networkPolicy == .enabled)
        #expect(runtime.syncServerURL == URL(string: "http://127.0.0.1:18080"))
        #expect(runtime.allowsNetwork)
    }

    @Test("offline network mode keeps the production local identity")
    func offlineModeIsNotTestComposition() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "NovelAuthTests.runtime.\(UUID().uuidString)")
        )
        defaults.set("http://127.0.0.1:18080", forKey: FuminiwaRuntimeEnvironment.syncServerURLKey)

        let runtime = FuminiwaRuntimeEnvironment(
            userDefaults: defaults,
            environment: [FuminiwaRuntimeEnvironment.networkModeKey: "disabled"]
        )

        #expect(runtime.networkPolicy == .disabled)
        #expect(runtime.syncServerURL == nil)
        #expect(!runtime.allowsNetwork)
        #expect(!runtime.isTestProcess)
    }

    @Test("refresh rejects a stale generation and keeps the vault unchanged")
    func staleRefresh() async throws {
        let session = FuminiwaSession(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            accountID: "acct",
            accountAuthEpoch: 1,
            accountFence: "fence",
            refreshGeneration: 2
        )
        let vault = InMemoryAuthSessionVault(session: session)
        let transport = StubTransport(result: session)
        let coordinator = AuthSessionCoordinator(transport: transport, vault: vault)
        await #expect(throws: AuthError.staleResponse) {
            _ = try await coordinator.refresh()
        }
        #expect(try await vault.load() == session)
    }
}

private struct StubTransport: FuminiwaAuthTransport {
    let result: FuminiwaSession

    func createAppleChallenge() async throws -> AuthChallenge {
        fatalError()
    }

    func exchangeApple(
        challenge _: AuthChallenge,
        authorizationCode _: Data,
        identityToken _: Data,
        operationID _: UUID
    ) async throws -> FuminiwaSession {
        result
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        result
    }

    func revoke(session _: FuminiwaSession) async throws {}
}
