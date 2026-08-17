import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func checkpointIsAtomicReopensAndNoOpSucceeds() async throws {
    let root = temporaryStoreRoot("checkpoint")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "local")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let noOp = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 1
        ),
        scope: scopeA
    )
    #expect(noOp.noChanges)
    #expect(noOp.snapshotID == first.snapshotID)
    #expect(noOp.intentID == first.intentID)
    #expect(try await store.pendingIntents(scope: scopeA).count == 1)
    await store.close()

    let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
    let opened = try await reopened.open(workID: workID, scope: scopeA)
    #expect(opened.document == document)
    #expect(opened.summary.localGeneration == 1)
}

@Test
func failedCheckpointLeavesHeadAndIntentUnchanged() async throws {
    let root = temporaryStoreRoot("atomic-failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "before")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    var changed = document
    changed.title = "must not commit"
    do {
        _ = try await store.checkpoint(
            V2CheckpointRequest(
                workID: workID,
                document: changed,
                documentCreatedAt: testDate.addingTimeInterval(60),
                expectedGeneration: 1
            ),
            scope: scopeA
        )
        Issue.record("anchor change committed")
    } catch SyncV2StoreError.generationMismatch {}
    let opened = try await store.open(workID: workID, scope: scopeA)
    #expect(opened.document == document)
    #expect(opened.summary.currentSnapshotID == first.snapshotID)
    #expect(try await store.pendingIntents(scope: scopeA).count == 1)
}

@Test
func unboundWorkStaysLocalAndExplicitAccountMoveClonesNewIdentity() async throws {
    let root = temporaryStoreRoot("unbound-clone")
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceWorkID = WorkID(UUID())
    let destinationWorkID = WorkID(UUID())
    let sourceDocument = makeDocument(title: "offline")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: sourceWorkID,
            document: sourceDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: .unbound
    )
    #expect(try await store.listWorks(scope: .unbound).map(\.workID) == [sourceWorkID])
    #expect(try await store.listWorks(scope: scopeA).isEmpty)

    let destinationDocumentID = DocumentID(UUID())
    _ = try await store.prepareExplicitAccountClone(
        sourceWorkID: sourceWorkID,
        sourceScope: .unbound,
        newWorkID: destinationWorkID,
        newDocumentID: destinationDocumentID,
        destination: bindingA
    )
    let original = try await store.open(workID: sourceWorkID, scope: .unbound)
    let clone = try await store.open(workID: destinationWorkID, scope: scopeA)
    #expect(original.document == sourceDocument)
    #expect(clone.document?.title == sourceDocument.title)
    #expect(clone.document?.id == destinationDocumentID.rawValue)
    #expect(try await store.listWorks(scope: .unbound).map(\.workID) == [sourceWorkID])
    #expect(try await store.listWorks(scope: scopeA).map(\.workID) == [destinationWorkID])
}

@Test
func exactAccountScopeDoesNotDiscloseForeignWork() async throws {
    let root = temporaryStoreRoot("accounts")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "private")
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    let bindingB = V2AccountBinding(
        accountID: "account-b",
        accountFence: "fence-b",
        serverInstanceID: "server-a"
    )
    let scopeB = V2LocalWorkScope.bound(bindingB)
    #expect(try await store.listWorks(scope: scopeB).isEmpty)
    #expect(try await store.pendingIntents(scope: scopeB).isEmpty)
    do {
        _ = try await store.open(workID: workID, scope: scopeB)
        Issue.record("foreign work disclosed")
    } catch SyncV2StoreError.workNotFound {}
    do {
        _ = try await store.checkpoint(
            V2CheckpointRequest(
                workID: workID,
                document: document,
                documentCreatedAt: testDate,
                expectedGeneration: 1
            ),
            scope: scopeB
        )
        Issue.record("foreign checkpoint returned noChanges")
    } catch SyncV2StoreError.workNotFound {}
}

@Test
func openPolicyUnknownDatabaseAndSymlinkFailClosed() async throws {
    let parent = temporaryStoreRoot("open-policy")
    defer { try? FileManager.default.removeItem(at: parent) }
    let missing = parent.appendingPathComponent("missing")
    #expect(throws: SyncV2StoreError.databaseMissing) {
        _ = try LocalSyncV2Store(root: missing, policy: .openExisting)
    }
    let partial = parent.appendingPathComponent("partial")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data().write(to: partial.appendingPathComponent("snapshot-sync-v2.sqlite"))
    #expect(throws: SyncV2StoreError.schemaMismatch) {
        _ = try LocalSyncV2Store(root: partial, policy: .openExisting)
    }
    let link = parent.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: partial)
    #expect(throws: SyncV2StoreError.invalidRoot) {
        _ = try LocalSyncV2Store(root: link, policy: .openExisting)
    }
    let altered = parent.appendingPathComponent("altered")
    let store = try LocalSyncV2Store(root: altered, policy: .createNew)
    await store.close()
    #expect(try sqliteExecutionSucceeded(
        databaseURL: altered.appendingPathComponent("snapshot-sync-v2.sqlite"),
        sql: "CREATE TRIGGER unexpected AFTER UPDATE ON works BEGIN SELECT 1; END"
    ))
    #expect(throws: SyncV2StoreError.schemaMismatch) {
        _ = try LocalSyncV2Store(root: altered, policy: .openExisting)
    }
}

@Test
func createNewNeverOpensAnExistingDatabase() async throws {
    let root = temporaryStoreRoot("create-new")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    await store.close()
    #expect(throws: SyncV2StoreError.databaseAlreadyExists) {
        _ = try LocalSyncV2Store(root: root, policy: .createNew)
    }
}

@Test
func schemaResourceExactlyMatchesTheReviewedDDL() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let reviewed = try Data(contentsOf: repository.appendingPathComponent(
        "docs/sync/v2/sqlite.sql"
    ))
    #expect(try SnapshotSyncV2SchemaContract.resourceSQL() == reviewed)
    #expect(SnapshotSyncV2SchemaContract.checksum(reviewed).count == 32)
}

@Test
func schemaRejectsMismatchedIntentFenceAndUnknownKeepBothCommand() async throws {
    let root = temporaryStoreRoot("schema-foreign-keys")
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceWorkID = WorkID(UUID())
    let newWorkID = WorkID(UUID())
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let fixture = try await createConflict(store: store, workID: sourceWorkID)
    _ = try await store.prepareKeepBoth(
        V2KeepBothPreparationRequest(
            workID: sourceWorkID,
            conflictID: fixture.conflict.conflictID,
            revision: fixture.conflict.revision,
            sourceGeneration: fixture.conflict.sourceGeneration,
            localSnapshotID: fixture.conflict.localSnapshotID,
            remoteSnapshotID: fixture.conflict.remoteSnapshotID,
            newWorkID: newWorkID,
            newDocumentID: DocumentID(UUID())
        ),
        scope: scopeA
    )
    guard let objectID = fixture.remote.encoded.objects.keys.first else {
        Issue.record("conflict fixture has no content object")
        return
    }
    await store.close()
    let databaseURL = root.appendingPathComponent("snapshot-sync-v2.sqlite")
    let mismatchedFence = joinedJSON(
        "INSERT INTO sync_intents(",
        "intent_id,work_id,source_snapshot_id,source_generation,kind,status,",
        "scope_kind,server_instance_id,protocol_epoch,account_id,account_fence,created_at",
        ") VALUES('", UUID().uuidString.lowercased(), "','", sourceWorkID.description,
        "',X'", fixture.localCheckpoint.snapshotID.rawValue,
        "',1,'checkpoint','pending','bound','server-a',2,'account-a',",
        "'mismatched-fence','2026-08-17T00:00:00Z')"
    )
    #expect(try sqliteRejectedByConstraint(
        databaseURL: databaseURL,
        sql: mismatchedFence
    ))
    let unknownCommand = joinedJSON(
        "UPDATE pending_keep_both SET command_id='",
        UUID().uuidString.lowercased(), "' WHERE source_work_id='",
        sourceWorkID.description, "'"
    )
    #expect(try sqliteRejectedByConstraint(
        databaseURL: databaseURL,
        sql: unknownCommand
    ))
    #expect(try sqliteRejectedByConstraint(
        databaseURL: databaseURL,
        sql: "UPDATE objects SET bytes=X'00',byte_count=1 WHERE object_id=X'\(objectID.rawValue)'"
    ))
    #expect(try sqliteRejectedByConstraint(
        databaseURL: databaseURL,
        sql: joinedJSON(
            "UPDATE snapshots SET created_at='changed' WHERE snapshot_id=X'",
            fixture.localCheckpoint.snapshotID.rawValue, "'"
        )
    ))
    #expect(try sqliteRejectedByConstraint(
        databaseURL: databaseURL,
        sql: joinedJSON(
            "UPDATE conflict_candidates SET pinned=1 WHERE conflict_id='",
            fixture.conflict.conflictID.uuidString.lowercased(), "'"
        )
    ))
    #expect(try sqliteRejectedByConstraint(
        databaseURL: databaseURL,
        sql: joinedJSON(
            "DELETE FROM conflict_candidates WHERE conflict_id='",
            fixture.conflict.conflictID.uuidString.lowercased(), "'"
        )
    ))
}
