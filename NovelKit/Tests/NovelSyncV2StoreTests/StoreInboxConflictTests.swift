import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func remoteOnlyNonRootGraphStagesVerifiesAdoptsAndReplays() async throws {
    let root = temporaryStoreRoot("remote-graph")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let documentID = UUID()
    let rootDocument = makeDocument(title: "remote root", id: documentID)
    let rootSnapshot = try encodeSnapshot(workID: workID, document: rootDocument)
    var childDocument = rootDocument
    childDocument.title = "remote child"
    let child = try encodeSnapshot(
        workID: workID,
        document: childDocument,
        parents: [rootSnapshot.snapshotId]
    )
    let remoteHead = try V2RemoteHead(snapshotID: child.snapshotId, generation: 2)
    let graph = V2RemoteSnapshotGraph(
        workID: workID,
        headSnapshotID: child.snapshotId,
        snapshots: [child, rootSnapshot],
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 0,
        expectedRemoteHead: remoteHead
    )
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.stageRemoteGraph(graph, scope: scopeA)
    try await store.stageRemoteGraph(graph, scope: scopeA)
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    try await store.adoptInbox(inboxID: graph.inboxID, scope: scopeA)
    try await store.adoptInbox(inboxID: graph.inboxID, scope: scopeA)
    try await store.stageRemoteGraph(graph, scope: scopeA)
    let opened = try await store.open(workID: workID, scope: scopeA)
    #expect(opened.document?.title == "remote child")
    #expect(opened.summary.currentSnapshotID == child.snapshotId)
    #expect(opened.summary.acknowledgedHeadGeneration == 2)
    #expect(try await store.snapshotParents(
        workID: workID,
        snapshotID: child.snapshotId,
        scope: scopeA
    ) == [rootSnapshot.snapshotId])
}

@Test
func incompleteDisconnectedAndAnchorChangingGraphsFailWithoutBootstrap() async throws {
    let root = temporaryStoreRoot("invalid-graphs")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let first = try encodeSnapshot(
        workID: workID,
        document: makeDocument(title: "root")
    )
    let child = try encodeSnapshot(
        workID: workID,
        document: makeDocument(title: "child"),
        parents: [first.snapshotId]
    )
    let incomplete = V2RemoteSnapshotGraph(
        workID: workID,
        headSnapshotID: child.snapshotId,
        snapshots: [child],
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 0
    )
    do {
        try await store.stageRemoteGraph(incomplete, scope: scopeA)
        Issue.record("incomplete closure bootstrapped a work")
    } catch SyncV2StoreError.invalidSnapshot {}
    #expect(try await store.listWorks(scope: scopeA).isEmpty)

    let disconnected = V2RemoteSnapshotGraph(
        workID: workID,
        headSnapshotID: first.snapshotId,
        snapshots: [first, child],
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 0
    )
    do {
        try await store.stageRemoteGraph(disconnected, scope: scopeA)
        Issue.record("disconnected snapshot was accepted")
    } catch SyncV2StoreError.invalidSnapshot {}
    #expect(try await store.listWorks(scope: scopeA).isEmpty)
}

@Test
func inboxRetryRequiresEveryMetadataFieldAndExactBytes() async throws {
    let root = temporaryStoreRoot("inbox-retry")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "remote")
    let encoded = try encodeSnapshot(workID: workID, document: document)
    let remoteHead = try V2RemoteHead(snapshotID: encoded.snapshotId, generation: 1)
    let original = V2RemoteSnapshotGraph(
        workID: workID,
        headSnapshotID: encoded.snapshotId,
        snapshots: [encoded],
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 0,
        expectedRemoteHead: remoteHead
    )
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.stageRemoteGraph(original, scope: scopeA)
    let mismatch = V2RemoteSnapshotGraph(
        inboxID: original.inboxID,
        workID: workID,
        headSnapshotID: encoded.snapshotId,
        snapshots: [encoded],
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 1,
        expectedRemoteHead: remoteHead
    )
    do {
        try await store.stageRemoteGraph(mismatch, scope: scopeA)
        Issue.record("inbox identity accepted changed CAS metadata")
    } catch SyncV2StoreError.invalidSnapshot {}
    try await store.verifyInbox(inboxID: original.inboxID, scope: scopeA)
    try await store.adoptInbox(inboxID: original.inboxID, scope: scopeA)
    #expect(try await store.open(workID: workID, scope: scopeA).document == document)
}

@Test
func inboxVerificationRejectsBatchManifestThatDiffersFromHeadBytes() async throws {
    let root = temporaryStoreRoot("inbox-batch-manifest")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let encoded = try encodeSnapshot(
        workID: workID,
        document: makeDocument(title: "remote")
    )
    let graph = try V2RemoteSnapshotGraph(
        workID: workID,
        headSnapshotID: encoded.snapshotId,
        snapshots: [encoded],
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 0,
        expectedRemoteHead: V2RemoteHead(
            snapshotID: encoded.snapshotId,
            generation: 1
        )
    )
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    try await store.stageRemoteGraph(graph, scope: scopeA)
    #expect(try sqliteExecutionSucceeded(
        databaseURL: root.appendingPathComponent("snapshot-sync-v2.sqlite"),
        sql: joinedJSON(
            "UPDATE inbox_batches SET manifest_bytes=X'00' WHERE inbox_id='",
            graph.inboxID.uuidString.lowercased(), "'"
        )
    ))
    do {
        try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
        Issue.record("batch/head manifest mismatch was verified")
    } catch SyncV2StoreError.invalidSnapshot {}
}

@Test
func inboxRejectsRemoteHeadThatDoesNotNameGraphHead() async throws {
    let root = temporaryStoreRoot("inbox-head-binding")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let encoded = try encodeSnapshot(
        workID: workID,
        document: makeDocument(title: "remote")
    )
    let otherSnapshot = try SnapshotID(rawValue: String(repeating: "b", count: 64))
    let graph = try V2RemoteSnapshotGraph(
        workID: workID,
        headSnapshotID: encoded.snapshotId,
        snapshots: [encoded],
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 0,
        expectedRemoteHead: V2RemoteHead(snapshotID: otherSnapshot, generation: 1)
    )
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    do {
        try await store.stageRemoteGraph(graph, scope: scopeA)
        Issue.record("graph head and remote head were not bound")
    } catch SyncV2StoreError.invalidSnapshot {}
    #expect(try await store.listWorks(scope: scopeA).isEmpty)
}

@Test
func conflictRedeliveryIsIdempotentAcrossInboxIDs() async throws {
    let root = temporaryStoreRoot("conflict-dedupe")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: workID)
    let redelivery = V2RemoteSnapshot(
        workID: workID,
        encoded: fixture.remote.encoded,
        expectedCurrentSnapshotID: fixture.localCheckpoint.snapshotID,
        expectedLocalGeneration: fixture.localCheckpoint.generation,
        expectedRemoteHead: fixture.remoteHead
    )
    let duplicate = try await store.appendConflict(
        workID: workID,
        baseSnapshotID: fixture.baseCheckpoint.snapshotID,
        localSnapshotID: fixture.localCheckpoint.snapshotID,
        remote: redelivery,
        sourceGeneration: fixture.localCheckpoint.generation,
        scope: scopeA
    )
    #expect(duplicate.conflictID == fixture.conflict.conflictID)
    #expect(duplicate.revision == fixture.conflict.revision)
}

@Test
func ordinaryInboxAdoptionCannotBypassAnActiveConflict() async throws {
    let root = temporaryStoreRoot("nil-conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: workID)
    let otherDocument = NovelDocument(
        id: fixture.localDocument.id,
        title: "other remote",
        chapters: fixture.localDocument.chapters
    )
    let other = try encodeSnapshot(
        workID: workID,
        document: otherDocument,
        parents: [fixture.baseCheckpoint.snapshotID]
    )
    let inbox = try V2RemoteSnapshot(
        workID: workID,
        encoded: other,
        expectedCurrentSnapshotID: fixture.localCheckpoint.snapshotID,
        expectedLocalGeneration: fixture.localCheckpoint.generation,
        expectedRemoteHead: V2RemoteHead(snapshotID: other.snapshotId, generation: 3)
    )
    try await store.stageRemote(inbox, scope: scopeA)
    try await store.verifyInbox(inboxID: inbox.inboxID, scope: scopeA)
    do {
        try await store.adoptInbox(inboxID: inbox.inboxID, scope: scopeA)
        Issue.record("ordinary adoption bypassed an active conflict")
    } catch SyncV2StoreError.staleConflictAction {}
    let opened = try await store.open(workID: workID, scope: scopeA)
    #expect(opened.summary.currentSnapshotID == fixture.localCheckpoint.snapshotID)
    #expect(opened.document?.title == fixture.localDocument.title)
    #expect(try await store.activeConflict(workID: workID, scope: scopeA) != nil)
}

@Test
func useServerReceiptPinsLocalInstallsRemoteAndCreatesNoIntent() async throws {
    let root = temporaryStoreRoot("use-server")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: workID)
    let command = try resolveServerCommand(
        workID: workID,
        conflict: fixture.conflict
    )
    try await store.seal(command, scope: scopeA)
    try await store.acknowledge(
        commandAcknowledgement(command, head: fixture.remoteHead),
        scope: scopeA
    )
    let opened = try await store.open(workID: workID, scope: scopeA)
    let history = try await store.history(workID: workID, scope: scopeA)
    #expect(opened.document?.title == "remote")
    #expect(try await store.activeConflict(workID: workID, scope: scopeA) == nil)
    #expect(try await store.pendingIntents(scope: scopeA).isEmpty)
    #expect(history.contains {
        $0.snapshotID == fixture.localCheckpoint.snapshotID && $0.pinned
    })
}

@Test
func useServerReceiptAdvancesBaselineWithoutOverwritingNewerEdit() async throws {
    let root = temporaryStoreRoot("use-server-newer")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: workID)
    let command = try resolveServerCommand(
        workID: workID,
        conflict: fixture.conflict
    )
    try await store.seal(command, scope: scopeA)
    var newerDocument = fixture.localDocument
    newerDocument.title = "typed after server choice"
    let newer = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: newerDocument,
            documentCreatedAt: testDate,
            expectedGeneration: fixture.conflict.sourceGeneration
        ),
        scope: scopeA
    )

    try await store.acknowledge(
        commandAcknowledgement(command, head: fixture.remoteHead),
        scope: scopeA
    )

    let opened = try await store.open(workID: workID, scope: scopeA)
    let pending = try await store.pendingIntents(scope: scopeA, workID: workID)
    let history = try await store.history(workID: workID, scope: scopeA)
    #expect(opened.document?.title == "typed after server choice")
    #expect(opened.summary.currentSnapshotID == newer.snapshotID)
    #expect(pending.count == 1)
    #expect(pending[0].sourceSnapshotID == newer.snapshotID)
    #expect(try await store.activeConflict(workID: workID, scope: scopeA) == nil)
    #expect(history.contains {
        $0.snapshotID == fixture.localCheckpoint.snapshotID && $0.pinned
    })
    #expect(history.contains {
        $0.snapshotID == fixture.remote.encoded.snapshotId && $0.reason == "remoteBaseline"
    })
    #expect(try await store.receiptReadback(
        commandID: command.commandId,
        scope: scopeA
    )?.result == .applied)
}

@Test
func useDeviceReceiptDoesNotLoseEditsTypedAfterResolutionStarted() async throws {
    let root = temporaryStoreRoot("use-device-newer")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: workID)
    let decision = try await store.prepareUseDevice(
        V2DeviceResolutionRequest(
            workID: workID,
            conflictID: fixture.conflict.conflictID,
            revision: fixture.conflict.revision,
            sourceGeneration: fixture.conflict.sourceGeneration,
            localSnapshotID: fixture.conflict.localSnapshotID,
            remoteSnapshotID: fixture.conflict.remoteSnapshotID,
            inboxID: fixture.remote.inboxID,
            remoteHead: fixture.remoteHead
        ),
        scope: scopeA
    )
    #expect(try await store.snapshotParents(
        workID: workID,
        snapshotID: decision.snapshotID,
        scope: scopeA
    ) == [fixture.conflict.localSnapshotID, fixture.conflict.remoteSnapshotID].sorted {
        $0.rawValue < $1.rawValue
    })
    let command = try resolveDeviceCommand(
        workID: workID,
        conflict: fixture.conflict,
        decision: decision,
        expectedHead: fixture.remoteHead
    )
    try await store.seal(command, intentID: decision.intentID, scope: scopeA)
    var newer = fixture.localDocument
    newer.title = "typed after choice"
    let newerCheckpoint = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: newer,
            documentCreatedAt: testDate,
            expectedGeneration: decision.generation
        ),
        scope: scopeA
    )
    try await store.acknowledge(
        commandAcknowledgement(
            command,
            head: V2RemoteHead(
                snapshotID: decision.snapshotID,
                generation: fixture.remoteHead.generation + 1
            )
        ),
        scope: scopeA
    )
    let opened = try await store.open(workID: workID, scope: scopeA)
    let pending = try await store.pendingIntents(scope: scopeA)
    #expect(opened.document?.title == "typed after choice")
    #expect(opened.summary.currentSnapshotID == newerCheckpoint.snapshotID)
    #expect(pending.count == 1)
    #expect(pending[0].sourceSnapshotID == newerCheckpoint.snapshotID)
    #expect(try await store.activeConflict(workID: workID, scope: scopeA) == nil)
}
