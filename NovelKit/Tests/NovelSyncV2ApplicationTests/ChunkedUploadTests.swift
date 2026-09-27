import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import Testing

@Suite(.serialized)
struct ChunkedUploadTests {
    @Test("large uploads use bounded ranges and acknowledge only after every chunk", arguments: [204, 413, 404])
    func boundedRequests(status: Int) async throws {
        let auth = FuminiwaSession(
            binding: AuthSessionBinding(serverInstanceID: UUID(), syncProtocolEpoch: 2, accountID: "test", accountAuthEpoch: 1, accountFence: "fence", sessionID: UUID()),
            tokens: AuthSessionTokens(accessToken: "synthetic", accessTokenExpiresAt: .distantFuture, refreshToken: "synthetic-refresh", refreshTokenExpiresAt: .distantFuture, refreshGeneration: 1),
            receipt: AuthReceipt(commandKind: "test", operationID: UUID(), replayUntil: .distantFuture)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkUploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ChunkUploadURLProtocol.responses = ChunkUploadResponses(status: status)
        let client = try ProductionSyncV2RemoteClient(
            origin: ProductionHTTPSOrigin(url: #require(URL(string: "https://chunk.test"))),
            vault: InMemoryAuthSessionVault(session: auth), session: session
        )
        let bytes = Data(repeating: 0x61, count: 8 * 1024 * 1024 + 3)
        let transfer = SyncV2UploadTransfer(
            transferID: UUID(), workID: WorkID(UUID()), uploadID: UUID(),
            objectID: ObjectID(data: bytes), exactBytes: bytes, acknowledgedOffset: 0,
            expiresAt: .distantFuture, capability: "fixture"
        )
        if status == 204 {
            guard case let .upload(result) = try await client.upload(transfer, session: auth) else {
                Issue.record("upload did not complete")
                return
            }
            #expect(result.acknowledgedByteCount == bytes.count)
            #expect(ChunkUploadURLProtocol.responses?.ranges == ["bytes 0-8388607/8388611", "bytes 8388608-8388610/8388611"])
        } else {
            await #expect(throws: SyncV2Failure.fatal(status == 413 ? .uploadTooLarge : .remoteDataUnavailable)) {
                _ = try await client.upload(transfer, session: auth)
            }
            #expect(ChunkUploadURLProtocol.responses?.ranges.count == 1)
        }
    }
}

private final class ChunkUploadResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    let status: Int
    init(status: Int) {
        self.status = status
    }

    var ranges: [String] {
        lock.withLock { recorded }
    }

    func record(_ request: URLRequest) {
        lock.withLock { recorded.append(request.value(forHTTPHeaderField: "Content-Range") ?? "missing") }
    }
}

private final class ChunkUploadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: ChunkUploadResponses?
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let state = Self.responses, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: state.status, httpVersion: nil,
                                             headerFields: ["X-Fuminiwa-Result": "applied", "Cache-Control": "no-store", "Pragma": "no-cache"]) else { return }
        state.record(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
