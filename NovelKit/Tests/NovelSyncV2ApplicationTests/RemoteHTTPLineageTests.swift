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
    @Test("a temporary failure resumes the failed graph request without restarting history", arguments: ["head", "manifest", "object"], [false, true])
    func transientGraphRequestResumes(stage: String, disconnected: Bool) async throws {
        let fixture = LineageFixture()
        let base = try fixture.snapshot(title: "base")
        let head = try fixture.snapshot(title: "head", parents: [base.snapshotId])
        let objectID = try #require(base.objects.keys.first)
        let path = switch stage {
        case "head": "/v2/works/\(fixture.workID.description)/head"
        case "manifest": "/v2/snapshots/\(base.snapshotId.rawValue)/manifest"
        default: "/v2/objects/\(objectID.rawValue)"
        }
        let state = LineageHTTPState(workID: fixture.workID, snapshots: [base, head], publishResponse: nil)
        state.failNext(path: path, replies: [LineageHTTPReply(
            status: 502, headers: [:], body: Data(),
            transportError: disconnected ? .networkConnectionLost : nil
        )])
        let client = try fixture.client(snapshots: [], overrideState: state)
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(inbox.snapshots.map(\.snapshotId) == [base.snapshotId, head.snapshotId])
        #expect(state.count(path: path) == 2)
        #expect(state.count(path: "/v2/snapshots/\(head.snapshotId.rawValue)/manifest") == 1)
    }

    @Test("persistent graph failures are bounded and authorization failures are not retried", arguments: [403, 404, 429, 503])
    func graphRequestFailureIsBounded(status: Int) async throws {
        let fixture = LineageFixture()
        let path = "/v2/works/\(fixture.workID.description)/head"
        let state = LineageHTTPState(replies: [
            "GET \(path)": LineageHTTPReply(status: status, headers: [:], body: Data())
        ])
        let client = try fixture.client(snapshots: [], overrideState: state)
        let expected: SyncV2Failure = switch status {
        case 403: .accountFenceChanged
        case 404: .fatal(.remoteDataUnavailable)
        case 429: .retryable(.rateLimited)
        default: .retryable(.serverUnavailable)
        }
        await #expect(throws: expected) { try await client.downloadRemoteOnly(workID: fixture.workID) }
        #expect(state.count(path: path) == (status == 503 ? 3 : 1))
    }

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
            RemoteConflictAppendRequest(
                store: store,
                fixture: fixture,
                conflict: conflict,
                inbox: inbox,
                remote: remote,
                localSnapshotID: local.snapshotId
            )
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
        let sharedObjects = Set(base.objects.keys).intersection(decision.objects.keys)
        #expect(!sharedObjects.isEmpty)
        for objectID in sharedObjects {
            #expect(fixture.requestCount(path: "/v2/objects/\(objectID.rawValue)") == 1)
        }
    }

    @Test("object budget is enforced before object download")
    func graphObjectBudgetFailsClosed() async throws {
        let fixture = LineageFixture()
        let snapshot = try fixture.snapshot(title: "budget")
        let client = try fixture.client(snapshots: [snapshot])
        let session = try await client.loadSession()
        await #expect(throws: SyncV2Failure.quarantined(.invalidRemoteData)) {
            try await client.fetchSnapshot(
                workID: fixture.workID, id: snapshot.snapshotId, session: session,
                traversal: SnapshotFetchTraversal(maximumObjects: snapshot.objects.count - 1)
            )
        }
        for objectID in snapshot.objects.keys {
            #expect(fixture.requestCount(path: "/v2/objects/\(objectID.rawValue)") == 0)
        }
    }

    @Test("cancelled history traversal does not fetch or return a partial graph")
    func cancelledTraversalStopsBeforeFetching() async throws {
        let fixture = LineageFixture()
        let snapshot = try fixture.snapshot(title: "cancel")
        let client = try fixture.client(snapshots: [snapshot])
        let session = try await client.loadSession()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.fetchSnapshot(
                workID: fixture.workID, id: snapshot.snapshotId, session: session,
                traversal: SnapshotFetchTraversal()
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.requestCount(path: "/v2/snapshots/\(snapshot.snapshotId.rawValue)/manifest") == 0)
    }

    @Test("a cold device imports 512 snapshots without a history-count cutoff")
    func longHistoryImportsIntoEmptyStore() async throws {
        let fixture = LineageFixture()
        var snapshots: [EncodedSnapshot] = []
        var parent: SnapshotID?
        for index in 0 ..< 512 {
            let snapshot = try fixture.snapshot(
                title: "\(index)",
                parents: parent.map { [$0] } ?? []
            )
            snapshots.append(snapshot)
            parent = snapshot.snapshotId
        }
        let client = try fixture.client(snapshots: snapshots)

        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(inbox.snapshots.map(\.snapshotId) == snapshots.map(\.snapshotId))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let scope = V2LocalWorkScope.bound(fixture.binding)
        let graph = try V2RemoteSnapshotGraph(
            inboxID: inbox.inboxID, workID: fixture.workID, headSnapshotID: inbox.headSnapshotID,
            snapshots: inbox.snapshots, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
            expectedRemoteHead: V2RemoteHead(snapshotID: inbox.headSnapshotID,
                                             generation: inbox.expectedRemoteHead.generation)
        )
        try await store.stageRemoteGraph(graph, scope: scope)
        try await store.verifyInbox(inboxID: inbox.inboxID, scope: scope)
        try await store.adoptInbox(inboxID: inbox.inboxID, scope: scope)
        let opened = try await store.open(workID: fixture.workID, scope: scope)
        #expect(opened.document == fixture.document(title: "511"))
        #expect(opened.summary.currentSnapshotID == snapshots.last?.snapshotId)
        await store.close()
    }
}

private struct RemoteConflictAppendRequest {
    let store: LocalSyncV2Store
    let fixture: LineageFixture
    let conflict: SyncV2ConflictProjection
    let inbox: SyncV2RemoteInbox
    let remote: EncodedSnapshot
    let localSnapshotID: SnapshotID
}

private func appendRemoteConflict(
    _ request: RemoteConflictAppendRequest
) async throws -> V2ConflictCandidate {
    let fixture = request.fixture
    let conflict = request.conflict
    let inbox = request.inbox
    let remote = request.remote
    let localSnapshotID = request.localSnapshotID
    return try await request.store.appendConflict(
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

struct LineageFixture: Sendable {
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
        publishResponse: Data? = nil,
        overrideState: LineageHTTPState? = nil,
        localStore: LocalSyncV2Store? = nil
    ) throws -> ProductionSyncV2RemoteClient {
        let state = overrideState ?? LineageHTTPState(
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
            session: session,
            localStore: localStore
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

extension RemoteHTTPLineageTests {
    @Test("verified unadopted history is reusable without bypassing Inbox verification")
    func verifiedInboxAnchorsLaterDownload() async throws {
        let fixture = LineageFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let scope = V2LocalWorkScope.bound(fixture.binding)
        let saved = try await store.checkpoint(V2CheckpointRequest(
            workID: fixture.workID, document: fixture.document,
            documentCreatedAt: fixture.createdAt, expectedGeneration: 0
        ), scope: scope)
        var parent = saved.snapshotID
        var snapshots: [EncodedSnapshot] = []
        for index in 0 ..< 130 {
            let snapshot = try fixture.snapshot(title: "received-\(index)", parents: [parent])
            snapshots.append(snapshot)
            parent = snapshot.snapshotId
        }
        let staged = try V2RemoteSnapshotGraph(
            workID: fixture.workID, headSnapshotID: parent, snapshots: snapshots,
            expectedCurrentSnapshotID: saved.snapshotID, expectedLocalGeneration: saved.generation,
            expectedRemoteHead: V2RemoteHead(snapshotID: parent, generation: 131)
        )
        try await store.stageRemoteGraph(staged, scope: scope)
        #expect(try await store.verifiedInboxSnapshot(workID: fixture.workID, snapshotID: parent, scope: scope) == nil)
        try await store.verifyInbox(inboxID: staged.inboxID, scope: scope)
        let remote = try fixture.snapshot(title: "new remote", parents: [parent])
        let client = try fixture.client(snapshots: [remote], localStore: store)
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(inbox.snapshots.count == 132)
        #expect(fixture.requestCount(path: "/v2/snapshots/\(parent.rawValue)/manifest") == 0)
        #expect(try await store.open(workID: fixture.workID, scope: scope).summary.currentSnapshotID == saved.snapshotID)
        let graph = try V2RemoteSnapshotGraph(
            workID: fixture.workID, headSnapshotID: remote.snapshotId, snapshots: inbox.snapshots,
            expectedCurrentSnapshotID: saved.snapshotID, expectedLocalGeneration: saved.generation,
            expectedRemoteHead: V2RemoteHead(snapshotID: remote.snapshotId, generation: 132)
        )
        try await store.stageRemoteGraph(graph, scope: scope)
        try await store.verifyInbox(inboxID: graph.inboxID, scope: scope)
        let wrongScope = V2LocalWorkScope.bound(V2AccountBinding(
            accountID: "other-account", accountFence: fixture.binding.accountFence,
            serverInstanceID: fixture.binding.serverInstanceID
        ))
        #expect(try await store.verifiedInboxSnapshot(workID: fixture.workID, snapshotID: parent, scope: wrongScope) == nil)
        await store.close()
    }

    @Test("only an exact pre-commit publish lineage rejection permits replanning", arguments: [false, true])
    func publishLineageRejectionIsTyped(exact: Bool) async throws {
        let fixture = LineageFixture()
        let base = try fixture.snapshot(title: "base")
        let local = try fixture.snapshot(title: "local", parents: [base.snapshotId])
        let command = try fixture.publishCommand(source: local,
                                                 expectedRemoteHead: V2RemoteHead(snapshotID: base.snapshotId, generation: 1))
        let body = exact
            ? Data(#"{"error":"lineageViolation","result":"parked","retryable":false}"#.utf8)
            : Data(#"{"error":"schemaViolation","result":"parked","retryable":false}"#.utf8)
        let state = LineageHTTPState(replies: [
            "POST /v2/works/\(fixture.workID.description)/publish": LineageHTTPReply(
                status: 422,
                headers: ["Content-Type": "application/vnd.fuminiwa.sync.v2+jcs", "Cache-Control": "no-store", "Pragma": "no-cache"],
                body: body
            )
        ])
        let client = try fixture.client(snapshots: [], overrideState: state)
        await #expect(throws: exact ? SyncV2Failure.retryable(.publishLineageRejected) : .fatal(.unexpected)) {
            _ = try await client.execute(.command(SyncV2SealedRemoteCommand(command: command)))
        }
        #expect(state.count(path: "/v2/receipts/\(command.commandId.uuidString.lowercased())") == 0)
    }

    @Test("committed lineage beyond the network budget is reused without downloading ancestors", arguments: [false, true])
    func longCommittedHistoryAnchorsRemoteGraph(remoteChanged: Bool) async throws {
        let fixture = LineageFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let scope = V2LocalWorkScope.bound(fixture.binding)
        var head: SnapshotID?
        for generation in 0 ..< 130 {
            let saved = try await store.checkpoint(V2CheckpointRequest(
                workID: fixture.workID,
                document: fixture.document(title: "local-\(generation)"),
                documentCreatedAt: fixture.createdAt,
                expectedGeneration: Int64(generation)
            ), scope: scope)
            head = saved.snapshotID
        }
        let anchor = try #require(head)
        let remote = try await remoteChanged
            ? fixture.snapshot(title: "remote", parents: [anchor])
            : #require(store.committedSnapshot(workID: fixture.workID, snapshotID: anchor, scope: scope))
        // The stub deliberately contains no local history. A redundant GET
        // would fail, rather than silently passing against a full server fixture.
        let client = try fixture.client(snapshots: [remote], localStore: store)
        let inbox = try await client.downloadRemoteOnly(workID: fixture.workID)
        #expect(inbox.snapshots.map(\.snapshotId) == (remoteChanged ? [anchor, remote.snapshotId] : [anchor]))
        #expect(fixture.requestCount(path: "/v2/snapshots/\(anchor.rawValue)/manifest") == 0)
        let graph = try V2RemoteSnapshotGraph(
            inboxID: inbox.inboxID,
            workID: fixture.workID,
            headSnapshotID: remote.snapshotId,
            snapshots: inbox.snapshots,
            expectedCurrentSnapshotID: anchor,
            expectedLocalGeneration: 130,
            expectedRemoteHead: V2RemoteHead(snapshotID: remote.snapshotId, generation: 131)
        )
        try await store.stageRemoteGraph(graph, scope: scope)
        try await store.verifyInbox(inboxID: inbox.inboxID, scope: scope)
        #expect(try await store.open(workID: fixture.workID, scope: scope).summary.currentSnapshotID == anchor)
        let wrongFence = V2LocalWorkScope.bound(V2AccountBinding(
            accountID: fixture.binding.accountID,
            accountFence: "different-fence",
            serverInstanceID: fixture.binding.serverInstanceID
        ))
        #expect(try await store.committedSnapshot(workID: fixture.workID, snapshotID: anchor, scope: wrongFence) == nil)
        #expect(try await store.committedSnapshot(workID: WorkID(UUID()), snapshotID: anchor, scope: scope) == nil)
        await store.close()
    }

    @Test("HTTP create response is read back before durable acknowledgement", arguments: [false, true])
    func createReceiptReachesStore(tampered: Bool) async throws {
        let fixture = LineageFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let scope = V2LocalWorkScope.bound(fixture.binding)
        let saved = try await store.checkpoint(V2CheckpointRequest(
            workID: fixture.workID, document: fixture.document,
            documentCreatedAt: fixture.createdAt, expectedGeneration: 0
        ), scope: scope)
        let command = try SealedCommand.decodeCanonical(productionJSON([
            "binding": ["accountFence": fixture.binding.accountFence, "accountId": fixture.binding.accountID,
                        "protocolEpoch": 2, "serverInstanceId": fixture.binding.serverInstanceID],
            "commandId": UUID().uuidString.lowercased(), "commandKind": "createWork", "schemaVersion": 2,
            "sourceGeneration": saved.generation, "sourceSnapshotId": saved.snapshotID.rawValue,
            "payload": ["documentId": fixture.documentID.uuidString.lowercased(), "workId": fixture.workID.description]
        ]))
        try await store.seal(command, scope: scope)
        _ = try await store.markSending(commandID: command.commandId, scope: scope)
        let response = try productionJSON([
            "commandId": command.commandId.uuidString.lowercased(), "commandKind": "createWork",
            "documentId": fixture.documentID.uuidString.lowercased(), "head": NSNull(),
            "workId": fixture.workID.description, "result": "applied",
            "receipt": ["commandId": command.commandId.uuidString.lowercased(), "commandKind": "createWork",
                        "workId": fixture.workID.description, "requestDigest": command.requestDigest.rawValue,
                        "readBack": productionReadBack()]
        ])
        let envelope = try productionEnvelope(command: command, response: tampered ? Data("{}".utf8) : response,
                                              result: .applied, status: 201)
        let headers = ["Content-Type": "application/vnd.fuminiwa.sync.v2+jcs", "Cache-Control": "no-store", "Pragma": "no-cache"]
        let receiptPath = "/v2/receipts/\(command.commandId.uuidString.lowercased())"
        let state = LineageHTTPState(replies: [
            "POST /v2/works": LineageHTTPReply(status: 201, headers: headers, body: response),
            "GET \(receiptPath)": LineageHTTPReply(status: 200, headers: headers, body: envelope)
        ])
        let client = try fixture.client(snapshots: [], overrideState: state)
        if tampered {
            await #expect(throws: SyncV2Failure.receiptMismatch) {
                _ = try await client.execute(.command(SyncV2SealedRemoteCommand(command: command)))
            }
            #expect(try await store.receiptReadback(commandID: command.commandId, scope: scope) == nil)
        } else {
            let result = try await client.execute(.command(SyncV2SealedRemoteCommand(command: command)))
            guard case let .command(receipt, _) = result else { Issue.record("missing receipt"); return }
            try await store.acknowledge(V2CommandAcknowledgement(commandID: command.commandId,
                                                                 canonicalReceiptEnvelope: receipt.canonicalResponse), scope: scope)
            #expect(try await store.allSealedCommands(scope: scope, workID: fixture.workID).first?.lifecycle == .completed)
            #expect(try await store.pendingIntents(scope: scope).count == 1)
        }
        #expect(state.count(path: receiptPath) == 1)
        await store.close()
    }
}
