import Foundation
import NovelAuth
import Testing

@Suite("Provider-neutral auth")
struct AuthDomainTests {
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
