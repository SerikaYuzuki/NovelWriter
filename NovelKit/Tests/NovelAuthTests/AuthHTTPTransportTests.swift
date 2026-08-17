import Foundation
import NovelAuth
import Testing

@Suite("Auth v1 strict HTTP transport", .serialized)
// swiftlint:disable:next type_body_length
struct AuthHTTPTransportTests {
    @Test("challenge sends exact JCS body, media type, and client version")
    func challengeRequestWire() async throws {
        let operationID = try #require(UUID(uuidString: "10000000-0000-4000-8000-000000000002"))
        let state = try makeTransport { _ in
            .init(status: 201, headers: Self.noStoreHeaders, body: Self.challengeBody(operationID: operationID))
        }
        _ = try await state.transport.createAppleChallenge(clientPlatform: .macos, operationID: operationID)
        let request = try #require(state.protocolState.lastRequest())
        let expected = "{\"clientPlatform\":\"macos\",\"flow\":\"native\",\"operationId\":\"10000000-0000-4000-8000-000000000002\",\"provider\":\"apple\"}"
        #expect(request.httpBody == Data(expected.utf8))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.fuminiwa.auth.v1+jcs")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.fuminiwa.auth.v1+jcs")
        #expect(request.value(forHTTPHeaderField: "X-Fuminiwa-Client-Version") == "0.1.0")
    }

    @Test("capabilities provide typed receipt limits and sync epoch 2")
    func capabilitiesTypedLimits() async throws {
        let state = try makeTransport { _ in
            .init(status: 200, headers: Self.noStoreHeaders, body: Self.capabilitiesBody())
        }
        let capabilities = try await state.transport.fetchCapabilities()
        #expect(capabilities.authProtocolEpoch == 1)
        #expect(capabilities.syncProtocolEpoch == 2)
        #expect(capabilities.limits.authReceiptLifetimeSeconds == 7_776_000)
        #expect(capabilities.providers.count == 1)
        #expect(capabilities.providers[0].requestedScopes.isEmpty)
    }

    @Test("capabilities reject the retired sync epoch 1")
    func capabilitiesOldSyncEpoch() async throws {
        let body = Data(String(decoding: Self.capabilitiesBody(), as: UTF8.self)
            .replacingOccurrences(of: "\"syncProtocolEpoch\":2", with: "\"syncProtocolEpoch\":1")
            .utf8)
        let state = try makeTransport { _ in
            .init(status: 200, headers: Self.noStoreHeaders, body: body)
        }
        await expectAuthError(.invalidResponseSemantics) {
            _ = try await state.transport.fetchCapabilities()
        }
    }

    @Test("valid nested exchange response is accepted at sync epoch 2")
    func validNestedExchange() async throws {
        let operationID = try #require(UUID(uuidString: "30000000-0000-4000-8000-000000000001"))
        let challenge = Self.challenge(operationID: UUID(uuidString: "10000000-0000-4000-8000-000000000002") ?? UUID())
        let state = try makeTransport { _ in
            .init(status: 200, headers: Self.noStoreHeaders, body: Self.sessionBody(command: "exchangeAppleNativeCredential", operationID: operationID, epoch: 2))
        }
        let session = try await state.transport.exchangeApple(
            challenge: challenge,
            authorizationCode: Data("fixture-apple-code-success".utf8),
            identityToken: Data("fixtureHeader.fixturePayload.fixtureSignature".utf8),
            operationID: operationID
        )
        #expect(session.syncProtocolEpoch == 2)
        #expect(session.tokens.tokenType == "Bearer")
        let request = try #require(state.protocolState.lastRequest())
        let expected = "{\"authorizationCode\":\"fixture-apple-code-success\","
            + "\"challengeId\":\"20000000-0000-4000-8000-000000000001\","
            + "\"identityToken\":\"fixtureHeader.fixturePayload.fixtureSignature\","
            + "\"operationId\":\"30000000-0000-4000-8000-000000000001\","
            + "\"provider\":\"apple\",\"state\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}"
        #expect(request.httpBody == Data(expected.utf8))
    }

    @Test("old sync epoch is rejected before a session can be adopted")
    func oldEpochRejected() async throws {
        let operationID = try #require(UUID(uuidString: "30000000-0000-4000-8000-000000000001"))
        let challenge = Self.challenge(operationID: UUID(uuidString: "10000000-0000-4000-8000-000000000002") ?? UUID())
        let state = try makeTransport { _ in
            .init(status: 200, headers: Self.noStoreHeaders, body: Self.sessionBody(command: "exchangeAppleNativeCredential", operationID: operationID, epoch: 1))
        }
        await expectAuthError(.invalidResponseSemantics) {
            _ = try await state.transport.exchangeApple(challenge: challenge, authorizationCode: Data("code".utf8), identityToken: Data("header.payload.signature".utf8), operationID: operationID)
        }
    }

    @Test("missing no-store response fails closed")
    func missingNoStore() async throws {
        let operationID = try #require(UUID(uuidString: "10000000-0000-4000-8000-000000000002"))
        let state = try makeTransport { _ in
            .init(status: 201, headers: ["Content-Type": Self.mediaType, "Pragma": "no-cache"], body: Self.challengeBody(operationID: operationID))
        }
        await expectAuthError(.missingNoStore) {
            _ = try await state.transport.createAppleChallenge(clientPlatform: .macos, operationID: operationID)
        }
    }

    @Test("wrong media type fails closed")
    func wrongMediaType() async throws {
        let operationID = try #require(UUID(uuidString: "10000000-0000-4000-8000-000000000002"))
        let state = try makeTransport { _ in
            .init(status: 201, headers: ["Content-Type": "application/json", "Cache-Control": "no-store", "Pragma": "no-cache"], body: Self.challengeBody(operationID: operationID))
        }
        await expectAuthError(.invalidMediaType) {
            _ = try await state.transport.createAppleChallenge(clientPlatform: .macos, operationID: operationID)
        }
    }

    @Test("duplicate response member is rejected instead of discarded")
    func duplicateResponseMember() async throws {
        let operationID = try #require(UUID(uuidString: "10000000-0000-4000-8000-000000000002"))
        var duplicateBody = Self.challengeBody(operationID: operationID)
        duplicateBody.removeLast()
        duplicateBody.append(contentsOf: Data(",\"state\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}".utf8))
        let body = duplicateBody
        let state = try makeTransport { _ in
            .init(status: 201, headers: Self.noStoreHeaders, body: body)
        }
        await expectAuthError(.invalidCanonicalResponse) {
            _ = try await state.transport.createAppleChallenge(clientPlatform: .macos, operationID: operationID)
        }
    }

    @Test("noncanonical response whitespace is rejected")
    func nonCanonicalResponse() async throws {
        let operationID = try #require(UUID(uuidString: "10000000-0000-4000-8000-000000000002"))
        let body = Data(" {\"x\":1} ".utf8)
        let state = try makeTransport { _ in
            .init(status: 201, headers: Self.noStoreHeaders, body: body)
        }
        await expectAuthError(.invalidCanonicalResponse) {
            _ = try await state.transport.createAppleChallenge(clientPlatform: .macos, operationID: operationID)
        }
    }

    @Test("wrong receipt operation id is rejected")
    func wrongReceipt() async throws {
        let operationID = try #require(UUID(uuidString: "10000000-0000-4000-8000-000000000002"))
        let wrongID = try #require(UUID(uuidString: "10000000-0000-4000-8000-000000000003"))
        let state = try makeTransport { _ in
            .init(status: 201, headers: Self.noStoreHeaders, body: Self.challengeBody(operationID: wrongID))
        }
        await expectAuthError(.invalidResponseSemantics) {
            _ = try await state.transport.createAppleChallenge(clientPlatform: .macos, operationID: operationID)
        }
    }

    @Test("refresh sends exact rotation body and refresh bearer")
    func refreshRequestWire() async throws {
        let rotationID = try #require(UUID(uuidString: "50000000-0000-4000-8000-000000000001"))
        let current = Self.session()
        let state = try makeTransport { _ in
            .init(status: 200, headers: Self.noStoreHeaders, body: Self.refreshBody(rotationID: rotationID))
        }
        _ = try await state.transport.refresh(session: current, rotationID: rotationID)
        let request = try #require(state.protocolState.lastRequest())
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(current.refreshToken)")
        #expect(request.httpBody == Data("{\"rotationId\":\"50000000-0000-4000-8000-000000000001\"}".utf8))
    }

    @Test("revoke sends the closed operation body and refresh bearer")
    func revokeRequestWire() async throws {
        let operationID = try #require(UUID(uuidString: "70000000-0000-4000-8000-000000000001"))
        let current = Self.session()
        let state = try makeTransport { _ in
            .init(status: 200, headers: Self.noStoreHeaders, body: Self.revokeBody(operationID: operationID))
        }
        try await state.transport.revoke(pending: Self.pendingRevoke(session: current, operationID: operationID))
        let request = try #require(state.protocolState.lastRequest())
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(current.refreshToken)")
        #expect(request.httpBody == Data("{\"operationId\":\"70000000-0000-4000-8000-000000000001\",\"scope\":\"currentSession\"}".utf8))
    }

    @Test("refresh receipt and binding must remain exact")
    func refreshWrongReceipt() async throws {
        let rotationID = try #require(UUID(uuidString: "50000000-0000-4000-8000-000000000001"))
        let wrongID = try #require(UUID(uuidString: "50000000-0000-4000-8000-000000000002"))
        let state = try makeTransport { _ in
            .init(status: 200, headers: Self.noStoreHeaders, body: Self.refreshBody(rotationID: wrongID))
        }
        await expectAuthError(.invalidResponseSemantics) {
            _ = try await state.transport.refresh(session: Self.session(), rotationID: rotationID)
        }
    }

    @Test("refresh cannot change the session binding")
    func refreshBindingInvariant() async throws {
        let rotationID = try #require(UUID(uuidString: "50000000-0000-4000-8000-000000000001"))
        let current = Self.session()
        let body = Data(String(decoding: Self.refreshBody(rotationID: rotationID), as: UTF8.self)
            .replacingOccurrences(of: "fence_AAAAAAAAAAAAAAAAAAAA", with: "fence_BBBBBBBBBBBBBBBBBBBB")
            .utf8)
        let state = try makeTransport { _ in
            .init(status: 200, headers: Self.noStoreHeaders, body: body)
        }
        await expectAuthError(.invalidResponseSemantics) {
            _ = try await state.transport.refresh(session: current, rotationID: rotationID)
        }
    }

    @Test("non-ASCII lookalikes are rejected in opaque binding values")
    func nonASCIIOpaqueValue() async throws {
        let operationID = try #require(UUID(uuidString: "30000000-0000-4000-8000-000000000001"))
        let challenge = Self.challenge(operationID: UUID(uuidString: "10000000-0000-4000-8000-000000000002") ?? UUID())
        let body = Data(String(decoding: Self.sessionBody(command: "exchangeAppleNativeCredential", operationID: operationID, epoch: 2), as: UTF8.self)
            .replacingOccurrences(of: "acct_AAAAAAAAAAAAAAAA", with: "acct_ＡＡＡＡＡＡＡＡＡＡＡＡＡＡＡＡ")
            .utf8)
        let state = try makeTransport { _ in
            .init(status: 200, headers: Self.noStoreHeaders, body: body)
        }
        await expectAuthError(.invalidResponseSemantics) {
            _ = try await state.transport.exchangeApple(
                challenge: challenge,
                authorizationCode: Data("code".utf8),
                identityToken: Data("header.payload.signature".utf8),
                operationID: operationID
            )
        }
    }

    @Test("semantic token validation rejects a non-Bearer token type")
    func invalidTokenType() async throws {
        let operationID = try #require(UUID(uuidString: "30000000-0000-4000-8000-000000000001"))
        let challenge = Self.challenge(operationID: UUID(uuidString: "10000000-0000-4000-8000-000000000002") ?? UUID())
        let body = Self.sessionBody(command: "exchangeAppleNativeCredential", operationID: operationID, epoch: 2, tokenType: "Basic")
        let state = try makeTransport { _ in .init(status: 200, headers: Self.noStoreHeaders, body: body) }
        await expectAuthError(.invalidResponseSemantics) {
            _ = try await state.transport.exchangeApple(challenge: challenge, authorizationCode: Data("code".utf8), identityToken: Data("header.payload.signature".utf8), operationID: operationID)
        }
    }

    @Test("provider exchange indeterminate is surfaced as typed restart error")
    func providerExchangeIndeterminate() async throws {
        let operationID = try #require(UUID(uuidString: "30000000-0000-4000-8000-000000000001"))
        let challenge = Self.challenge(operationID: UUID(uuidString: "10000000-0000-4000-8000-000000000002") ?? UUID())
        let state = try makeTransport { _ in
            .init(status: 502, headers: Self.noStoreHeaders, body: Self.providerExchangeIndeterminateBody(operationID: operationID))
        }
        do {
            _ = try await state.transport.exchangeApple(
                challenge: challenge,
                authorizationCode: Data("code".utf8),
                identityToken: Data("header.payload.signature".utf8),
                operationID: operationID
            )
            Issue.record("indeterminate exchange unexpectedly succeeded")
        } catch let error as AuthError {
            guard case let .remote(remote) = error else {
                Issue.record("unexpected auth error: \(error)")
                return
            }
            #expect(remote.code == "providerExchangeIndeterminate")
            #expect(remote.recoveryAction == .interactiveAppleSignIn)
            #expect(remote.retryability == .afterInteractiveAuthentication)
            #expect(remote.operationID == operationID)
        }
    }

    @Test("unknown or extra error members fail closed")
    func unknownErrorMember() async throws {
        let operationID = try #require(UUID(uuidString: "10000000-0000-4000-8000-000000000002"))
        let body = Data(("{\"code\":\"invalidRequest\","
                + "\"recoveryAction\":\"correctRequest\","
                + "\"requestId\":\"60000000-0000-4000-8000-000000000001\","
                + "\"retryability\":\"never\",\"unexpected\":\"reject\"}").utf8)
        let state = try makeTransport { _ in
            .init(status: 400, headers: Self.noStoreHeaders, body: body)
        }
        await expectAuthError(.invalidWireResponse) {
            _ = try await state.transport.createAppleChallenge(clientPlatform: .macos, operationID: operationID)
        }
    }

    private static let mediaType = "application/vnd.fuminiwa.auth.v1+jcs"
    private static let noStoreHeaders = ["Content-Type": mediaType, "Cache-Control": "no-store", "Pragma": "no-cache"]
    private static let now = Date(timeIntervalSince1970: 1_755_312_000)

    private struct TransportState {
        let transport: FuminiwaHTTPAuthTransport
        let protocolState: AuthURLProtocolState
    }

    private func makeTransport(_ reply: @escaping @Sendable (URLRequest) -> AuthURLProtocolReply) throws -> TransportState {
        let protocolState = AuthURLProtocolState(reply: reply)
        AuthURLProtocol.state = protocolState
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.urlCache = nil
        urlConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlConfiguration.protocolClasses = [AuthURLProtocol.self]
        let urlSession = URLSession(configuration: urlConfiguration)
        let configuration = try AuthClientConfiguration(origin: #require(URL(string: "https://sync.example.test")), clientVersion: "0.1.0", clientPlatform: .macos)
        let transport = try FuminiwaHTTPAuthTransport(configuration: configuration, session: urlSession, clock: { Self.now })
        return TransportState(transport: transport, protocolState: protocolState)
    }

    private static func challenge(operationID: UUID) -> AuthChallenge {
        AuthChallenge(
            challengeID: UUID(uuidString: "20000000-0000-4000-8000-000000000001") ?? UUID(),
            expiresAt: now.addingTimeInterval(300),
            audience: "dev.serikayuzuki.fuminiwa",
            providerConfigurationID: "apple-primary-fuminiwa-v1",
            state: String(repeating: "A", count: 43),
            nonce: String(repeating: "B", count: 43),
            receipt: AuthReceipt(commandKind: "createChallenge", operationID: operationID, replayUntil: now.addingTimeInterval(7_776_000))
        )
    }

    private static func session() -> FuminiwaSession {
        let binding = AuthSessionBinding(
            serverInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID(),
            syncProtocolEpoch: 2,
            accountID: "acct_AAAAAAAAAAAAAAAA",
            accountAuthEpoch: 1,
            accountFence: "fence_AAAAAAAAAAAAAAAAAAAA",
            sessionID: UUID(uuidString: "40000000-0000-4000-8000-000000000001") ?? UUID()
        )
        let tokens = AuthSessionTokens(
            accessToken: "fma1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            accessTokenExpiresAt: now.addingTimeInterval(900),
            refreshToken: "fmr1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            refreshTokenExpiresAt: now.addingTimeInterval(7_776_000),
            refreshGeneration: 1
        )
        return FuminiwaSession(
            binding: binding,
            tokens: tokens,
            receipt: AuthReceipt(
                commandKind: "exchangeAppleNativeCredential",
                operationID: UUID(uuidString: "30000000-0000-4000-8000-000000000001") ?? UUID(),
                replayUntil: now.addingTimeInterval(7_776_000)
            )
        )
    }

    private static func challengeBody(operationID: UUID) -> Data {
        let operation = operationID.uuidString.lowercased()
        let json = [
            "{\"audience\":\"dev.serikayuzuki.fuminiwa\",",
            "\"challengeId\":\"20000000-0000-4000-8000-000000000001\",",
            "\"expiresAt\":\"2025-08-16T02:45:00Z\",\"flow\":\"native\",",
            "\"nonce\":\"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\",\"provider\":\"apple\",",
            "\"providerConfigurationId\":\"apple-primary-fuminiwa-v1\",",
            "\"receipt\":{\"commandKind\":\"createChallenge\",\"operationId\":\"\(operation)\",",
            "\"replayUntil\":\"2026-05-05T16:53:20Z\"},\"requestedScopes\":[],",
            "\"state\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}"
        ].joined()
        return Data(json.utf8)
    }

    private static func capabilitiesBody() -> Data {
        let json = [
            "{\"authProtocolEpoch\":1,\"authProtocolNamespace\":\"com.fuminiwa.auth\",",
            "\"authProtocolVersion\":\"1.0.0\",\"canonicalization\":\"rfc8785-jcs\",",
            "\"contentProtection\":{\"e2ee\":false,\"profile\":\"serverReadableV1\",",
            "\"serverCanReadContent\":true,\"userManagedContentKey\":false},",
            "\"limits\":{\"accessTokenLifetimeSeconds\":900,\"authReceiptLifetimeSeconds\":7776000,",
            "\"challengeLifetimeSeconds\":300,\"maxCanonicalCommandBytes\":65536,",
            "\"maxProviderClockSkewSeconds\":300,\"refreshTokenLifetimeSeconds\":7776000},",
            "\"minimumClientVersion\":\"0.1.0\",\"providers\":[{",
            "\"authorizationEndpoint\":\"https://appleid.apple.com/auth/authorize\",",
            "\"clientPlatforms\":[\"ios\",\"ipados\",\"macos\"],\"flow\":\"native\",",
            "\"issuer\":\"https://appleid.apple.com\",\"jwksEndpoint\":\"https://appleid.apple.com/auth/keys\",",
            "\"nativeAudiences\":[{\"audience\":\"dev.serikayuzuki.fuminiwa\",\"clientPlatform\":\"macos\"},",
            "{\"audience\":\"dev.serikayuzuki.fuminiwa.ios\",\"clientPlatform\":\"ios\"},",
            "{\"audience\":\"dev.serikayuzuki.fuminiwa.ios\",\"clientPlatform\":\"ipados\"}],",
            "\"provider\":\"apple\",\"providerConfigurationId\":\"apple-primary-fuminiwa-v1\",",
            "\"requestedScopes\":[],\"tokenEndpoint\":\"https://appleid.apple.com/auth/token\"}],",
            "\"serverInstanceId\":\"00000000-0000-4000-8000-000000000001\",\"syncProtocolEpoch\":2,",
            "\"syncProtocolNamespace\":\"com.fuminiwa.snapshot-sync\"}"
        ].joined()
        return Data(json.utf8)
    }

    private static func sessionBody(command: String, operationID: UUID, epoch: UInt64, tokenType: String = "Bearer") -> Data {
        let receipt = if command == "rotateRefreshToken" {
            "{\"commandKind\":\"rotateRefreshToken\",\"replayUntil\":\"2026-05-05T16:53:20Z\",\"rotationId\":\"\(operationID.uuidString.lowercased())\"}"
        } else {
            "{\"commandKind\":\"exchangeAppleNativeCredential\",\"operationId\":\"\(operationID.uuidString.lowercased())\",\"replayUntil\":\"2026-05-05T16:53:20Z\"}"
        }
        let json = "{\"binding\":{\"accountAuthEpoch\":1,\"accountFence\":\"fence_AAAAAAAAAAAAAAAAAAAA\","
            + "\"accountId\":\"acct_AAAAAAAAAAAAAAAA\",\"serverInstanceId\":\"00000000-0000-4000-8000-000000000001\","
            + "\"sessionId\":\"40000000-0000-4000-8000-000000000001\",\"syncProtocolEpoch\":\(epoch)},"
            + "\"receipt\":\(receipt),\"tokens\":{\"accessToken\":\"fma1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\","
            + "\"accessTokenExpiresAt\":\"2025-08-16T02:55:00Z\",\"refreshGeneration\":2,"
            + "\"refreshToken\":\"fmr1_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\","
            + "\"refreshTokenExpiresAt\":\"2026-05-05T16:53:20Z\",\"tokenType\":\"\(tokenType)\"}}"
        return Data(json.utf8)
    }

    private static func refreshBody(rotationID: UUID) -> Data {
        sessionBody(command: "rotateRefreshToken", operationID: rotationID, epoch: 2)
    }

    private static func providerExchangeIndeterminateBody(operationID: UUID) -> Data {
        Data(("{\"challengeId\":\"20000000-0000-4000-8000-000000000001\","
                + "\"code\":\"providerExchangeIndeterminate\",\"operationId\":\"\(operationID.uuidString.lowercased())\","
                + "\"recoveryAction\":\"interactiveAppleSignIn\","
                + "\"requestId\":\"60000000-0000-4000-8000-000000000001\","
                + "\"retryability\":\"afterInteractiveAuthentication\"}").utf8)
    }

    private static func revokeBody(operationID: UUID) -> Data {
        Data(("{\"accountAuthEpoch\":1,\"accountFence\":\"fence_AAAAAAAAAAAAAAAAAAAA\","
                + "\"fenceChanged\":false,\"receipt\":{\"commandKind\":\"revokeCurrentSession\","
                + "\"operationId\":\"\(operationID.uuidString.lowercased())\",\"replayUntil\":\"2026-05-05T16:53:20Z\"},"
                + "\"revokedAt\":\"2025-08-16T02:40:00Z\",\"scope\":\"currentSession\"}").utf8)
    }

    private static func pendingRevoke(session: FuminiwaSession, operationID: UUID) -> AuthPendingRevoke {
        let command = AuthJCS.object([
            ("operationId", operationID.uuidString.lowercased()),
            ("scope", "currentSession")
        ])
        return AuthPendingRevoke(
            session: session,
            operationID: operationID,
            expiresAt: now.addingTimeInterval(86400),
            requestFingerprint: "revoke:\(session.sessionID.uuidString.lowercased())",
            canonicalRequest: command.bytes,
            requestDigest: command.sha256
        )
    }
}

private struct AuthURLProtocolReply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private final class AuthURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private let reply: @Sendable (URLRequest) -> AuthURLProtocolReply
    private var request: URLRequest?

    init(reply: @escaping @Sendable (URLRequest) -> AuthURLProtocolReply) {
        self.reply = reply
    }

    func response(for request: URLRequest) -> AuthURLProtocolReply {
        let request = requestWithMaterializedBody(request)
        lock.lock()
        self.request = request
        lock.unlock()
        return reply(request)
    }

    func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    private func requestWithMaterializedBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        var materialized = request
        materialized.httpBody = body
        return materialized
    }
}

private final class AuthURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var state: AuthURLProtocolState?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let state = Self.state else {
            client?.urlProtocol(self, didFailWithError: AuthError.providerRejected)
            return
        }
        let reply = state.response(for: request)
        guard let url = request.url ?? URL(string: "https://sync.example.test"),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: AuthError.providerRejected)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func expectAuthError(_ expected: AuthError, operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("operation unexpectedly succeeded")
    } catch let actual as AuthError {
        #expect(actual == expected)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
