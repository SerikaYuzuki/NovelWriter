import Foundation
import NovelAuth
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Snapshot Sync v2 remote auth refresh", .serialized)
struct RemoteAuthRefreshTests {
    @Test("concurrent refreshes consume one rotating token")
    func refreshIsSingleFlight() async throws {
        let session = refreshSession(binding: refreshBinding(account: "acct"), generation: 1)
        let vault = InMemoryAuthSessionVault(session: session)
        let transport = CountingRefreshTransport()
        let provider = try ProductionSyncV2SessionProvider(
            vault: vault,
            transport: transport,
            authLimits: limits()
        )

        async let first = provider.refresh(afterUnauthorizedFor: session)
        async let second = provider.refresh(afterUnauthorizedFor: session)
        async let third = provider.refresh(afterUnauthorizedFor: session)
        let results = try await [first, second, third]

        #expect(results.map(\.refreshGeneration) == [2, 2, 2])
        #expect(await transport.refreshCount() == 1)
    }

    @Test("account transition during refresh is rejected")
    func accountSwitchCannotJoinOldRefresh() async throws {
        let old = refreshSession(binding: refreshBinding(account: "acct-old"), generation: 1)
        let new = refreshSession(binding: refreshBinding(account: "acct-new"), generation: 1)
        let vault = InMemoryAuthSessionVault(session: old)
        let transport = CountingRefreshTransport()
        let provider = try ProductionSyncV2SessionProvider(
            vault: vault,
            transport: transport,
            authLimits: limits()
        )

        async let pending = provider.refresh(afterUnauthorizedFor: old)
        try await Task.sleep(for: .milliseconds(20))
        try await vault.save(new)
        do {
            _ = try await pending
            Issue.record("old-account refresh was accepted after account switch")
        } catch let error as SyncV2Failure {
            #expect(error == .accountFenceChanged)
        }
    }

    @Test("a second 401 is authenticationRequired and is not refreshed again")
    func secondUnauthorizedDoesNotLoop() async throws {
        let old = refreshSession(binding: refreshBinding(account: "acct"), generation: 1)
        let provider = FixedSessionProvider(session: old)
        Auth401URLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Auth401URLProtocol.self]
        let client = try ProductionSyncV2RemoteClient(
            origin: ProductionHTTPSOrigin(url: #require(URL(string: "https://auth-refresh.test"))),
            vault: InMemoryAuthSessionVault(session: old),
            session: URLSession(configuration: configuration),
            sessionProvider: provider
        )

        do {
            _ = try await client.catalogPage(cursor: nil, pageSize: 1)
            Issue.record("second 401 was accepted")
        } catch let error as SyncV2Failure {
            #expect(error == .authenticationRequired)
        }
        #expect(Auth401URLProtocol.requestCount == 2)
        #expect(await provider.refreshCount() == 1)
    }
}

private actor FixedSessionProvider: SyncV2SessionProvider {
    private var current: FuminiwaSession
    private var count = 0

    init(session: FuminiwaSession) {
        current = session
    }

    func session() async throws -> FuminiwaSession {
        current
    }

    func refresh(afterUnauthorizedFor _: FuminiwaSession) async throws -> FuminiwaSession {
        count += 1
        current = refreshSession(binding: current.binding, generation: current.refreshGeneration + 1)
        return current
    }

    func refreshCount() -> Int {
        count
    }
}

private final class Auth401URLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        requestCount = 0
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        let headers = [
            "Cache-Control": "no-store",
            "Pragma": "no-cache",
            "Content-Type": "application/vnd.fuminiwa.sync.v2+jcs"
        ]
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":"authenticationRequired"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor CountingRefreshTransport: FuminiwaAuthTransport {
    private var count = 0

    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID _: UUID) async throws -> AuthChallenge {
        throw AuthError.invalidProvider
    }

    func exchangeApple(challenge _: AuthChallenge, authorizationCode _: Data, identityToken _: Data, operationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.invalidProvider
    }

    func refresh(session current: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        count += 1
        try await Task.sleep(for: .milliseconds(80))
        return refreshSession(binding: current.binding, generation: current.refreshGeneration + 1)
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        throw AuthError.invalidProvider
    }

    func refreshCount() -> Int {
        count
    }
}

private func limits() throws -> AuthLimits {
    try AuthLimits(
        accessTokenLifetimeSeconds: 900,
        authReceiptLifetimeSeconds: 86400,
        challengeLifetimeSeconds: 300,
        maxCanonicalCommandBytes: 65536,
        maxProviderClockSkewSeconds: 300,
        refreshTokenLifetimeSeconds: 7_776_000
    )
}

private func refreshBinding(account: String) -> AuthSessionBinding {
    AuthSessionBinding(
        serverInstanceID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
        syncProtocolEpoch: 2,
        accountID: account,
        accountAuthEpoch: 1,
        accountFence: "fence-(account)",
        sessionID: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
    )
}

private func refreshSession(binding: AuthSessionBinding, generation: UInt64) -> FuminiwaSession {
    FuminiwaSession(
        binding: binding,
        tokens: AuthSessionTokens(
            accessToken: "fat_access_\(generation)",
            accessTokenExpiresAt: Date().addingTimeInterval(900),
            refreshToken: "fmr1_refresh_\(generation)",
            refreshTokenExpiresAt: Date().addingTimeInterval(7_776_000),
            refreshGeneration: generation
        ),
        receipt: AuthReceipt(
            commandKind: "rotateRefreshToken",
            operationID: UUID(),
            replayUntil: Date().addingTimeInterval(86400)
        )
    )
}
