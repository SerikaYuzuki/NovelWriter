import Foundation
import NovelAuth
import NovelAuthApple
import Testing

@Suite("Auth v1 wire and session safety")
struct AuthDomainTests {
    @Test("challenge creation JCS bytes are the fixture bytes")
    func challengeJCS() {
        let command = AuthJCS.object([
            ("clientPlatform", "macos"), ("flow", "native"),
            ("operationId", "10000000-0000-4000-8000-000000000002"), ("provider", "apple")
        ])
        #expect(String(decoding: command.bytes, as: UTF8.self) == "{\"clientPlatform\":\"macos\",\"flow\":\"native\",\"operationId\":\"10000000-0000-4000-8000-000000000002\",\"provider\":\"apple\"}")
        #expect(command.bytes.count == 114)
        #expect(command.sha256.map { String(format: "%02x", $0) }.joined() == "4f44d7abc543ae94b555744edecf0a67707a178460f017e59c511d0f1799ed53")
    }

    @Test("production auth origin is HTTPS and has a required client version")
    func productionConfiguration() throws {
        #expect(throws: AuthError.invalidProductionOrigin) {
            _ = try AuthClientConfiguration(origin: #require(URL(string: "http://127.0.0.1:18080")), clientVersion: "0.1.0", clientPlatform: .macos)
        }
        let config = try AuthClientConfiguration(origin: #require(URL(string: "https://sync.example.test")), clientVersion: "0.1.0", clientPlatform: .macos)
        #expect(config.clientPlatform == .macos)
    }

    @Test("refresh CAS keeps the newer generation")
    func staleRefresh() async throws {
        let session = fixtureSession(generation: 2, refresh: "fmr1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let newer = fixtureSession(generation: 3, refresh: "fmr1_DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD")
        let vault = InMemoryAuthSessionVault(session: newer)
        let replaced = try await vault.compareAndSwap(expectedRefreshToken: session.refreshToken, expectedGeneration: session.refreshGeneration, replacing: fixtureSession(generation: 3, refresh: "fmr1_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
        #expect(!replaced)
        #expect(try await vault.load() == newer)
    }

    @Test("Apple credential state handle has an isolated provider vault")
    func handleVault() async throws {
        let vault = InMemoryAppleCredentialStateHandleVault()
        try await vault.save("opaque-apple-user", providerConfigurationID: "apple-primary-fuminiwa-v1")
        #expect(try await vault.load(providerConfigurationID: "apple-primary-fuminiwa-v1") == "opaque-apple-user")
        #expect(try await vault.load(providerConfigurationID: "other") == nil)
    }

    private func fixtureSession(generation: UInt64, refresh: String) -> FuminiwaSession {
        let binding = AuthSessionBinding(serverInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, syncProtocolEpoch: 1, accountID: "acct_AAAAAAAAAAAAAAAA", accountAuthEpoch: 1, accountFence: "fence_AAAAAAAAAAAAAAAAAAAA", sessionID: UUID(uuidString: "40000000-0000-4000-8000-000000000001")!)
        let tokens = AuthSessionTokens(accessToken: "fma1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", accessTokenExpiresAt: Date(timeIntervalSince1970: 1_755_312_900), refreshToken: refresh, refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_778_000_000), refreshGeneration: generation)
        let receipt = AuthReceipt(commandKind: "exchangeAppleNativeCredential", operationID: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!, replayUntil: Date(timeIntervalSince1970: 1_778_000_000))
        return FuminiwaSession(binding: binding, tokens: tokens, receipt: receipt)
    }
}

private struct StubTransport: FuminiwaAuthTransport {
    let result: FuminiwaSession
    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID _: UUID) async throws -> AuthChallenge {
        fatalError()
    }

    func exchangeApple(challenge _: AuthChallenge, authorizationCode _: Data, identityToken _: Data, operationID _: UUID) async throws -> FuminiwaSession {
        result
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        result
    }

    func revoke(session _: FuminiwaSession, operationID _: UUID) async throws {}
}
