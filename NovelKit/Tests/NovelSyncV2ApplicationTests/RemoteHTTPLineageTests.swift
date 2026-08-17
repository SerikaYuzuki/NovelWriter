import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite("Snapshot Sync v2 remote HTTP lineage", .serialized)
struct RemoteHTTPLineageTests {
    @Test("publish conflict decodes its sealed base and store accepts B to L/R divergence")
    func publishConflictCarriesBaseIntoStore() async throws {
        let fixture = LineageFixture()
        let base = try fixture.snapshot(title: "B")
        let local = try fixture.snapshot(title: "L", parents: [base.snapshotId])
        let remote = try fixture.snapshot(title: "R", parents: [base.snapshotId])
        let command = try fixture.publishCommand(
            source: local,
            expectedRemoteHead: V2RemoteHead(
                snapshotID: base.snapshotId,
                generation: 1
            )
        )
        let conflictID = UUID()
        let client = try fixture.client(
            snapshots: [base, remote],
            publishResponse: fixture.conflictResponse(
                command: command,
                conflictID: conflictID,
                remote: remote,
                sourceGeneration: 2
            )
        )

        let execution = try await client.execute(
            .command(SyncV2SealedRemoteCommand(command: command))
        )
        guard case let .command(receipt, inbox?) = execution else {
            Issue.record("publish did not return a conflict inbox")
            return
        }
        let conflict = try #require(receipt.conflict)
        #expect(conflict.baseSnapshotID == base.snapshotId)
        #expect(conflict.localSnapshotID == local.snapshotId)
        #expect(conflict.remoteSnapshotID == remote.snapshotId)

        let (store, root) = try await makeStore(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = V2LocalWorkScope.bound(fixture.binding)
        let localState = try await store.open(workID: fixture.workID, scope: scope)
        #expect(localState.summary.localGeneration == 2)
        #expect(localState.summary.currentSnapshotID == local.snapshotId)
        let candidate = try await appendRemoteConflict(
            store: store,
            fixture: fixture,
            conflict: conflict,
            inbox: inbox,
            remote: remote,
            localSnapshotID: local.snapshotId
        )
        #expect(candidate.baseSnapshotID == base.snapshotId)
        #expect(try await store.activeConflict(workID: fixture.workID, scope: scope)?.baseSnapshotID == base.snapshotId)
    }

    @Test("shared parents are fetched once in deterministic postorder")
    func sharedParentsAreDeduplicated() async throws {
        let fixture = LineageFixture()
        let base = try fixture.snapshot(title: "B")
        let left = try fixture.snapshot(title: "L", parents: [base.snapshotId])
        let right = try fixture.snapshot(title: "R", parents: [base.snapshotId])
        let orderedParents = [left.snapshotId, right.snapshotId].sorted {
            $0.rawValue < $1.rawValue
        }
        let decision = try fixture.snapshot(title: "D", parents: orderedParents)
        let client = try fixture.client(snapshots: [base, left, right, decision])

        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        let expected = [base.snapshotId, orderedParents[0], orderedParents[1], decision.snapshotId]
        #expect(inbox.snapshots.map(\.snapshotId) == expected)
        #expect(Set(inbox.snapshots.map(\.snapshotId)).count == 4)
        #expect(fixture.requestCount(path: "/v2/snapshots/\(base.snapshotId.rawValue)/manifest") == 1)
    }

    @Test("lineage budget rejects an oversized graph")
    func oversizedGraphFailsClosed() async throws {
        let fixture = LineageFixture()
        var snapshots: [EncodedSnapshot] = []
        var parent: SnapshotID?
        for index in 0 ... 128 {
            let snapshot = try fixture.snapshot(
                title: "\(index)",
                parents: parent.map { [$0] } ?? []
            )
            snapshots.append(snapshot)
            parent = snapshot.snapshotId
        }
        let client = try fixture.client(snapshots: snapshots)

        do {
            _ = try await client.downloadRemoteOnly(workID: fixture.workID)
            Issue.record("oversized lineage was accepted")
        } catch let error as SyncV2Failure {
            #expect(error == .fatal(.invalidLocalState))
        }
    }
}

private func appendRemoteConflict(
    store: LocalSyncV2Store,
    fixture: LineageFixture,
    conflict: SyncV2ConflictProjection,
    inbox: SyncV2RemoteInbox,
    remote: EncodedSnapshot,
    localSnapshotID: SnapshotID
) async throws -> V2ConflictCandidate {
    try await store.appendConflict(
        workID: fixture.workID,
        baseSnapshotID: conflict.baseSnapshotID,
        localSnapshotID: localSnapshotID,
        remote: V2RemoteSnapshot(
            inboxID: inbox.inboxID,
            workID: fixture.workID,
            encoded: remote,
            expectedCurrentSnapshotID: localSnapshotID,
            expectedLocalGeneration: 2,
            expectedRemoteHead: V2RemoteHead(
                validatedSnapshotID: remote.snapshotId,
                generation: 2
            )
        ),
        sourceGeneration: 2,
        scope: .bound(fixture.binding)
    )
}

private func makeStore(
    fixture: LineageFixture
) async throws -> (LocalSyncV2Store, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fuminiwa-v2-http-lineage-\(UUID())")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let scope = V2LocalWorkScope.bound(fixture.binding)
    try await store.bootstrap(
        workID: fixture.workID,
        documentID: DocumentID(fixture.document.id),
        documentCreatedAt: fixture.createdAt,
        scope: scope
    )
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: fixture.workID,
            document: fixture.document,
            documentCreatedAt: fixture.createdAt,
            expectedGeneration: 0
        ),
        scope: scope
    )
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: fixture.workID,
            document: fixture.document(title: "L"),
            documentCreatedAt: fixture.createdAt,
            expectedGeneration: 1
        ),
        scope: scope
    )
    return (store, root)
}

private struct LineageFixture: Sendable {
    let workID = WorkID(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
    let documentID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    let serverID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    let binding = V2AccountBinding(
        accountID: "acct_lineage",
        accountFence: "fence_lineage",
        serverInstanceID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    )
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    var document: NovelDocument {
        document(title: "B")
    }

    func document(title: String) -> NovelDocument {
        NovelDocument(
            id: documentID,
            title: title,
            chapters: [
                Chapter(
                    id: ChapterID(rawValue: UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!),
                    title: "chapter",
                    content: title
                )
            ]
        )
    }

    func snapshot(title: String, parents: [SnapshotID] = []) throws -> EncodedSnapshot {
        try SnapshotCodec.encode(
            SnapshotModel(
                workId: workID,
                document: document(title: title),
                documentCreatedAt: createdAt
            ),
            parents: parents
        )
    }

    func publishCommand(
        source: EncodedSnapshot,
        expectedRemoteHead: V2RemoteHead
    ) throws -> SealedCommand {
        let payload = [
            "{\"candidateSnapshotId\":\"", source.snapshotId.rawValue,
            "\",\"expectedRemoteHead\":{\"generation\":",
            String(expectedRemoteHead.generation),
            ",\"snapshotId\":\"", expectedRemoteHead.snapshotID.rawValue,
            "\"},\"workId\":\"", workID.description, "\"}"
        ].joined()
        let envelope = [
            "{\"binding\":{\"accountFence\":\"", binding.accountFence,
            "\",\"accountId\":\"", binding.accountID,
            "\",\"protocolEpoch\":2,\"serverInstanceId\":\"",
            binding.serverInstanceID,
            "\"},\"commandId\":\"11111111-1111-4111-8111-111111111111\",",
            "\"commandKind\":\"publish\",\"payload\":", payload,
            ",\"schemaVersion\":2,\"sourceGeneration\":2,",
            "\"sourceSnapshotId\":\"", source.snapshotId.rawValue, "\"}"
        ].joined()
        let bytes = Data(envelope.utf8)
        return try SealedCommand.decodeCanonical(bytes)
    }

    func client(
        snapshots: [EncodedSnapshot],
        publishResponse: Data? = nil
    ) throws -> ProductionSyncV2RemoteClient {
        let state = LineageHTTPState(
            workID: workID,
            snapshots: snapshots,
            publishResponse: publishResponse
        )
        LineageURLProtocol.state = state
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LineageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let auth = FuminiwaSession(
            binding: AuthSessionBinding(
                serverInstanceID: serverID,
                syncProtocolEpoch: 2,
                accountID: binding.accountID,
                accountAuthEpoch: 1,
                accountFence: binding.accountFence,
                sessionID: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
            ),
            tokens: AuthSessionTokens(
                accessToken: "access",
                accessTokenExpiresAt: createdAt.addingTimeInterval(3600),
                refreshToken: "refresh",
                refreshTokenExpiresAt: createdAt.addingTimeInterval(7200),
                refreshGeneration: 1
            ),
            receipt: AuthReceipt(
                commandKind: "test",
                operationID: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
                replayUntil: createdAt.addingTimeInterval(7200)
            )
        )
        return try ProductionSyncV2RemoteClient(
            origin: ProductionHTTPSOrigin(url: URL(string: "https://lineage.test")!),
            vault: InMemoryAuthSessionVault(session: auth),
            session: session
        )
    }

    func conflictResponse(
        command: SealedCommand,
        conflictID: UUID,
        remote: EncodedSnapshot,
        sourceGeneration: Int64
    ) -> Data {
        canonicalJSON([
            "commandId": command.commandId.uuidString.lowercased(),
            "commandKind": command.commandKind,
            "conflictId": conflictID.uuidString.lowercased(),
            "conflictRevision": 1,
            "head": ["generation": 2, "snapshotId": remote.snapshotId.rawValue],
            "receipt": [
                "readBack": [
                    "accountMatched": true,
                    "commandDigestMatched": true,
                    "headMatched": true,
                    "resourceMatched": true,
                    "stateMatched": true
                ],
                "requestDigest": command.requestDigest.rawValue
            ],
            "result": "conflictPending",
            "sourceGeneration": sourceGeneration
        ])
    }

    private func canonicalJSON(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    func requestCount(path: String) -> Int {
        LineageURLProtocol.state?.count(path: path) ?? 0
    }
}

private struct LineageHTTPReply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private final class LineageHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String: LineageHTTPReply]
    private var paths: [String] = []

    init(workID: WorkID, snapshots: [EncodedSnapshot], publishResponse: Data?) {
        var replies: [String: LineageHTTPReply] = [:]
        let headers = [
            "Cache-Control": "no-store",
            "Pragma": "no-cache",
            "Content-Type": "application/vnd.fuminiwa.sync.v2+jcs"
        ]
        let head = snapshots.last!
        replies["GET /v2/works/\(workID.description)/head"] = LineageHTTPReply(
            status: 200,
            headers: headers,
            body: Data("{\"head\":{\"generation\":1,\"snapshotId\":\"\(head.snapshotId.rawValue)\"}}".utf8)
        )
        for snapshot in snapshots {
            let manifest = snapshot.manifestBytes.base64URLEncodedString()
            let body = [
                "{\"manifestBase64URL\":\"", manifest,
                "\",\"manifestBytesDigest\":\"",
                ObjectID(data: snapshot.manifestBytes).rawValue,
                "\",\"result\":\"noChanges\",\"snapshotId\":\"",
                snapshot.snapshotId.rawValue, "\"}"
            ].joined()
            replies["GET /v2/snapshots/\(snapshot.snapshotId.rawValue)/manifest"] = LineageHTTPReply(
                status: 200,
                headers: headers,
                body: Data(body.utf8)
            )
            for entry in snapshot.manifest.entries {
                replies["GET /v2/objects/\(entry.objectId.rawValue)"] = LineageHTTPReply(
                    status: 200,
                    headers: [
                        "Cache-Control": "no-store",
                        "Pragma": "no-cache",
                        "Content-Type": "application/octet-stream",
                        "X-Fuminiwa-Object-Digest": entry.objectId.rawValue,
                        "X-Fuminiwa-Byte-Count": String(snapshot.objects[entry.objectId]?.count ?? 0)
                    ],
                    body: snapshot.objects[entry.objectId] ?? Data()
                )
            }
        }
        if let publishResponse {
            let path = "POST /v2/works/\(workID.description)/publish"
            replies[path] = LineageHTTPReply(
                status: 409,
                headers: headers,
                body: publishResponse
            )
        }
        self.replies = replies
    }

    func reply(for request: URLRequest) -> LineageHTTPReply? {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        lock.lock()
        paths.append(path)
        lock.unlock()
        return replies["\(method) \(path)"]
    }

    func count(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count(where: { $0 == path })
    }
}

private class LineageURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var state: LineageHTTPState?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let reply = Self.state?.reply(for: request),
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: nil,
                  headerFields: reply.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
