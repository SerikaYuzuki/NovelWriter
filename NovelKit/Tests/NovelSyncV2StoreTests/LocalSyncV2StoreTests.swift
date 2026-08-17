import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func v2StoreBootstrapsIsolatedSchema() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server"))
    let version = try await store.schemaVersionAndChecksum()
    #expect(version.0 == "2")
    #expect(!version.1.isEmpty)
}

@Test
func embeddedSchemaResourceMatchesDecisionDocumentExactly() throws {
    var root = URL(fileURLWithPath: #filePath)
    var documentURL: URL?
    for _ in 0 ..< 6 {
        root.deleteLastPathComponent()
        let candidate = root.appendingPathComponent("docs/sync/v2/sqlite.sql")
        if FileManager.default.fileExists(atPath: candidate.path) {
            documentURL = candidate
            break
        }
    }
    let docsBytes = try Data(contentsOf: #require(documentURL))
    let resourceBytes = try SnapshotSyncV2SchemaContract.resourceSQL()
    #expect(resourceBytes == docsBytes)
    #expect(SnapshotSyncV2SchemaContract.checksum(resourceBytes).count == 32)
}

@Test
func checkpointCommitsWithoutNetworkAndReopensFromSQLite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID()); let document = NovelDocument(id: UUID(), title: "offline", chapters: [Chapter(title: "chapter")])
    let binding = V2AccountBinding(accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server")
    let store = try LocalSyncV2Store(root: root, binding: binding)
    let first = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: Date(timeIntervalSince1970: 1_700_000_000), expectedGeneration: 0))
    #expect(first.generation == 1)
    #expect(try await (store.pendingIntents()).count == 1)
    await store.close()
    let reopened = try LocalSyncV2Store(root: root, binding: binding)
    let opened = try await reopened.open(workID: workID)
    #expect(opened.document == document)
    #expect(opened.summary.localGeneration == 1)
}

@Test
func identicalCheckpointIsSuccessfulNoOp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID()); let document = NovelDocument.newDocument(title: "same")
    let store = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s"))
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: date, expectedGeneration: 0))
    let result = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: date, expectedGeneration: 1))
    #expect(result.noChanges)
    #expect(try await (store.pendingIntents()).count == 1)
}

@Test
func pendingCheckpointIntentIsCoalescedOnlyWhileUnsealed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    var document = NovelDocument.newDocument(title: "first")
    let store = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s"))
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let first = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: date, expectedGeneration: 0))
    document.title = "second"
    let second = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: date, expectedGeneration: 1))
    #expect(first.intentID == second.intentID)
    #expect(try await (store.pendingIntents()).count == 1)
    #expect(try await (store.pendingIntents()).first?.sourceGeneration == 2)
}

@Test
func accountScopeDoesNotDiscloseAnotherBinding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = NovelDocument.newDocument(title: "private")
    let storeA = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "account-a", accountFence: "fence-a", serverInstanceID: "s"))
    _ = try await storeA.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: Date(), expectedGeneration: 0))
    let storeB = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "account-b", accountFence: "fence-b", serverInstanceID: "s"))
    #expect(try await storeB.listWorks().isEmpty)
    do { _ = try await storeB.open(workID: workID); Issue.record("foreign work was disclosed") } catch SyncV2StoreError.workNotFound { } catch { Issue.record("unexpected error: \(error)") }
    #expect(try await storeB.pendingIntents().isEmpty)
}

@Test
func unknownDatabaseAndSymlinkRootFailClosed() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    let unknown = parent.appendingPathComponent("unknown")
    let symlink = parent.appendingPathComponent("link")
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
    try Data("legacy".utf8).write(to: unknown.appendingPathComponent("snapshot-sync-v2.sqlite"))
    #expect(throws: SyncV2StoreError.schemaMismatch) {
        _ = try LocalSyncV2Store(root: unknown, binding: V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s"))
    }
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unknown)
    #expect(throws: SyncV2StoreError.invalidRoot) {
        _ = try LocalSyncV2Store(root: symlink, binding: V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s"))
    }
}

@Test
func onlyOneActiveConflictIsKeptAndCandidatesAreAppended() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let binding = V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s")
    let store = try LocalSyncV2Store(root: root, binding: binding)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let local = NovelDocument.newDocument(title: "local")
    let first = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: local, documentCreatedAt: date, expectedGeneration: 0))
    let remoteOne = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: NovelDocument(id: local.id, title: "remote one", chapters: local.chapters), documentCreatedAt: date), parents: [first.snapshotID])
    let firstConflict = try await store.appendConflict(workID: workID, baseSnapshotID: first.snapshotID, localSnapshotID: first.snapshotID, remote: V2RemoteSnapshot(workID: workID, encoded: remoteOne, expectedCurrentSnapshotID: first.snapshotID, expectedLocalGeneration: 1), sourceGeneration: 1)
    let remoteTwo = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: NovelDocument(id: local.id, title: "remote two", chapters: local.chapters), documentCreatedAt: date), parents: [first.snapshotID])
    let secondConflict = try await store.appendConflict(workID: workID, baseSnapshotID: first.snapshotID, localSnapshotID: first.snapshotID, remote: V2RemoteSnapshot(workID: workID, encoded: remoteTwo, expectedCurrentSnapshotID: first.snapshotID, expectedLocalGeneration: 1), sourceGeneration: 1)
    #expect(firstConflict.conflictID == secondConflict.conflictID)
    #expect(secondConflict.revision == firstConflict.revision + 1)
    #expect(try await (store.activeConflict(workID: workID))?.revision == secondConflict.revision)
}

@Test
func sealedCommandReplayAndAckFenceKeepNewerEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let binding = V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s")
    let store = try LocalSyncV2Store(root: root, binding: binding)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let document = NovelDocument.newDocument(title: "ack")
    let checkpoint = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: date, expectedGeneration: 0))
    let commandID = UUID()
    let source = checkpoint.snapshotID.description
    let canonical = "{\"binding\":{\"accountFence\":\"f\",\"accountId\":\"a\",\"protocolEpoch\":2,\"serverInstanceId\":\"s\"},\"commandId\":\"\(commandID.uuidString.lowercased())\",\"commandKind\":\"publish\",\"payload\":{\"candidateSnapshotId\":\"\(source)\",\"expectedRemoteHead\":null,\"workId\":\"\(workID.description)\"},\"schemaVersion\":2,\"sourceGeneration\":1,\"sourceSnapshotId\":\"\(source)\"}"
    let sealed = try SealedCommand.decodeCanonical(Data(canonical.utf8))
    try await store.seal(sealed, intentID: checkpoint.intentID)
    let response = Data("{\"result\":\"applied\"}".utf8)
    try await store.acknowledge(commandID: commandID, responseStatus: 200, canonicalResponse: response, remoteHead: V2RemoteHead(snapshotID: checkpoint.snapshotID, generation: 7))
    try await store.acknowledge(commandID: commandID, responseStatus: 200, canonicalResponse: response, remoteHead: V2RemoteHead(snapshotID: checkpoint.snapshotID, generation: 7))
    #expect(try await store.pendingIntents().isEmpty)
    var newer = document
    newer.title = "newer"
    _ = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: newer, documentCreatedAt: date, expectedGeneration: 1))
    #expect(try await (store.pendingIntents()).count == 1)
}

@Test
func remoteAdoptionCASFailureKeepsLocalAndSuccessfulAdoptionPinsHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let binding = V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s")
    let store = try LocalSyncV2Store(root: root, binding: binding)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let local = NovelDocument.newDocument(title: "local")
    let first = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: local, documentCreatedAt: date, expectedGeneration: 0))
    let remoteDocument = NovelDocument(id: local.id, title: "remote", chapters: local.chapters)
    let remote = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: remoteDocument, documentCreatedAt: date), parents: [first.snapshotID])
    let inbox = V2RemoteSnapshot(workID: workID, encoded: remote, expectedCurrentSnapshotID: first.snapshotID, expectedLocalGeneration: 1)
    try await store.stageRemote(inbox); try await store.verifyInbox(inboxID: inbox.inboxID)
    var newer = local; newer.title = "newer local"
    _ = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: newer, documentCreatedAt: date, expectedGeneration: 1))
    do {
        try await store.adoptInbox(inboxID: inbox.inboxID)
        Issue.record("stale adoption unexpectedly succeeded")
    } catch SyncV2StoreError.staleCAS { } catch { Issue.record("unexpected error: \(error)") }
    #expect(try await (store.open(workID: workID)).document?.title == "newer local")
}

@Test
func serverAdoptionResolvesExactActiveConflictWithoutIntent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let binding = V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s")
    let store = try LocalSyncV2Store(root: root, binding: binding)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let local = NovelDocument.newDocument(title: "local")
    let first = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: local, documentCreatedAt: date, expectedGeneration: 0))
    let remoteDocument = NovelDocument(id: local.id, title: "remote", chapters: local.chapters)
    let remote = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: remoteDocument, documentCreatedAt: date), parents: [first.snapshotID])
    let inbox = V2RemoteSnapshot(workID: workID, encoded: remote, expectedCurrentSnapshotID: first.snapshotID, expectedLocalGeneration: 1)
    let conflict = try await store.appendConflict(workID: workID, baseSnapshotID: first.snapshotID, localSnapshotID: first.snapshotID, remote: inbox, sourceGeneration: 1)
    try await store.resolveServer(V2ServerResolutionRequest(workID: workID, conflictID: conflict.conflictID, revision: conflict.revision, sourceGeneration: conflict.sourceGeneration, localSnapshotID: conflict.localSnapshotID, remoteSnapshotID: conflict.remoteSnapshotID, inboxID: inbox.inboxID))
    #expect(try await store.activeConflict(workID: workID) == nil)
    #expect(try await store.historyCount(workID: workID) == 3)
    #expect(try await store.pendingIntents().count == 1)
    #expect(try await (store.open(workID: workID)).document?.title == "remote")
}

@Test
func unboundLocalScopeRemainsEditableButCannotSealOrStageRemote() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-unbound-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID()); let document = NovelDocument.newDocument(title: "offline")
    let store = try LocalSyncV2Store(root: root)
    let result = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: Date(), expectedGeneration: 0))
    #expect(try await store.listWorks().map(\.workID) == [workID])
    #expect(try await store.open(workID: workID).document == document)
    #expect(try await store.pendingIntents(workID: workID).count == 1)
    do {
        try await store.acknowledge(commandID: UUID(), responseStatus: 200, canonicalResponse: Data("{}".utf8), remoteHead: nil)
        Issue.record("unbound scope accepted a remote acknowledgement")
    } catch SyncV2StoreError.accountMismatch {}
    let encoded = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: document, documentCreatedAt: Date()), parents: [result.snapshotID])
    do {
        try await store.stageRemote(V2RemoteSnapshot(workID: workID, encoded: encoded, expectedCurrentSnapshotID: result.snapshotID, expectedLocalGeneration: result.generation))
        Issue.record("unbound scope accepted remote staging")
    } catch SyncV2StoreError.accountMismatch {}
}

@Test
func remoteOnlySnapshotBootstrapsBoundLocalWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-remote-only-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID()); let document = NovelDocument.newDocument(title: "remote")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let encoded = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: document, documentCreatedAt: date), parents: [])
    let store = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s"))
    let remote = V2RemoteSnapshot(workID: workID, encoded: encoded, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0)
    try await store.stageRemote(remote)
    try await store.verifyInbox(inboxID: remote.inboxID)
    try await store.adoptInbox(inboxID: remote.inboxID)
    #expect(try await store.open(workID: workID).document == document)
    #expect(try await store.listWorks().map(\.workID) == [workID])
}

@Test
func accountScopedCheckpointDoesNotReturnForeignNoOp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-account-checkpoint-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID()); let document = NovelDocument.newDocument(title: "private")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let storeA = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "a", accountFence: "fa", serverInstanceID: "s"))
    _ = try await storeA.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: date, expectedGeneration: 0))
    let storeB = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "b", accountFence: "fb", serverInstanceID: "s"))
    do {
        _ = try await storeB.checkpoint(V2CheckpointRequest(workID: workID, document: document, documentCreatedAt: date, expectedGeneration: 1))
        Issue.record("foreign checkpoint returned a result")
    } catch SyncV2StoreError.workNotFound {}
}

@Test
func useDevicePreparationCreatesTwoParentDecisionAndIntent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-device-choice-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID()); let local = NovelDocument.newDocument(title: "local"); let date = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s"))
    let first = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: local, documentCreatedAt: date, expectedGeneration: 0))
    let remoteDocument = NovelDocument(id: local.id, title: "remote", chapters: local.chapters)
    let remote = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: remoteDocument, documentCreatedAt: date), parents: [first.snapshotID])
    let inbox = V2RemoteSnapshot(workID: workID, encoded: remote, expectedCurrentSnapshotID: first.snapshotID, expectedLocalGeneration: 1)
    let conflict = try await store.appendConflict(workID: workID, baseSnapshotID: first.snapshotID, localSnapshotID: first.snapshotID, remote: inbox, sourceGeneration: 1)
    var decision = local; decision.title = "decision"
    let prepared = try await store.prepareUseDevice(V2DeviceResolutionRequest(workID: workID, conflictID: conflict.conflictID, revision: conflict.revision, sourceGeneration: conflict.sourceGeneration, localSnapshotID: conflict.localSnapshotID, remoteSnapshotID: conflict.remoteSnapshotID, remoteHead: V2RemoteHead(snapshotID: remote.snapshotId, generation: 2), document: decision, documentCreatedAt: date))
    #expect(prepared.generation == 2)
    #expect(try await store.open(workID: workID).document?.title == "decision")
    #expect(try await store.pendingIntents(workID: workID).contains { $0.intentID == prepared.intentID && $0.kind == "conflictResolution" })
}

@Test
func keepBothPreparationCreatesIndependentRootAndRestoreDoesNotRewind() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-v2-keep-restore-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID()); let local = NovelDocument.newDocument(title: "local"); let date = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try LocalSyncV2Store(root: root, binding: V2AccountBinding(accountID: "a", accountFence: "f", serverInstanceID: "s"))
    let first = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: local, documentCreatedAt: date, expectedGeneration: 0))
    var newer = local; newer.title = "newer"
    let second = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: newer, documentCreatedAt: date, expectedGeneration: 1))
    let remote = try SnapshotCodec.encode(SnapshotModel(workId: workID, document: NovelDocument(id: local.id, title: "remote", chapters: local.chapters), documentCreatedAt: date), parents: [first.snapshotID])
    let inbox = V2RemoteSnapshot(workID: workID, encoded: remote, expectedCurrentSnapshotID: second.snapshotID, expectedLocalGeneration: 2)
    let conflict = try await store.appendConflict(workID: workID, baseSnapshotID: first.snapshotID, localSnapshotID: second.snapshotID, remote: inbox, sourceGeneration: 2)
    let cloneID = WorkID(UUID())
    let clone = try await store.prepareKeepBoth(V2KeepBothPreparationRequest(workID: workID, conflictID: conflict.conflictID, revision: conflict.revision, sourceGeneration: conflict.sourceGeneration, localSnapshotID: conflict.localSnapshotID, remoteSnapshotID: conflict.remoteSnapshotID, newWorkID: cloneID, document: newer, documentCreatedAt: date))
    #expect(clone.generation == 1)
    #expect(try await store.open(workID: cloneID).document?.title == "newer")
    let restored = try await store.prepareRestore(V2RestorePreparationRequest(workID: workID, selectedSnapshotID: first.snapshotID, expectedLocalGeneration: 2))
    #expect(restored.generation == 3)
    #expect(try await store.open(workID: workID).document?.title == "local")
}
