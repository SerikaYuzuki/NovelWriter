import CSQLite
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
func emptyAttachmentBytesRoundTripThroughSQLite() async throws {
    let root = temporaryStoreRoot("empty-attachment")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let attachment = SyncAttachment(
        attachmentId: UUID(),
        fileName: "empty.txt",
        bytes: Data()
    )
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "empty attachment"),
            documentCreatedAt: testDate,
            expectedGeneration: 0,
            attachments: [attachment]
        ),
        scope: scopeA
    )
    let opened = try await store.open(workID: workID, scope: scopeA)
    #expect(opened.attachments == [attachment])
    #expect(opened.attachments.first?.bytes.isEmpty == true)
}

@Test
func noOpCheckpointKeepsIntentAndProtectsOnlyExplicitOccurrence() async throws {
    let root = temporaryStoreRoot("checkpoint-no-op-occurrence")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "no-op")
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
    let autosave = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: first.generation
        ),
        scope: scopeA
    )
    #expect(autosave.noChanges)
    #expect(try await store.historyCount(workID: workID, scope: scopeA) == 1)

    let explicit = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: first.generation,
            reason: .explicit
        ),
        scope: scopeA
    )
    #expect(explicit.noChanges)
    #expect(explicit.snapshotID == first.snapshotID)
    #expect(explicit.generation == first.generation)
    #expect(explicit.intentID == first.intentID)
    let history = try await store.history(workID: workID, scope: scopeA)
    #expect(history.count == 2)
    #expect(history.last?.snapshotID == first.snapshotID)
    #expect(history.last?.localGeneration == first.generation)
    #expect(history.last?.reason == V2CheckpointReason.explicit.rawValue)
    #expect(history.last?.pinned == true)
    #expect(try await store.pendingIntents(scope: scopeA).map(\.intentID) == [
        first.intentID
    ])

    do {
        _ = try await store.checkpoint(
            V2CheckpointRequest(
                workID: workID,
                document: document,
                documentCreatedAt: testDate,
                expectedGeneration: 0,
                reason: .explicit
            ),
            scope: scopeA
        )
        Issue.record("stale no-op checkpoint added an occurrence")
    } catch SyncV2StoreError.generationMismatch {}
    #expect(try await store.historyCount(workID: workID, scope: scopeA) == 2)
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
    let alteredBytes = try Data(contentsOf: altered.appendingPathComponent("snapshot-sync-v2.sqlite"))
    #expect(throws: SyncV2StoreError.schemaMismatch) {
        _ = try LocalSyncV2Store(root: altered, policy: .openExisting)
    }
    #expect(try Data(contentsOf: altered.appendingPathComponent("snapshot-sync-v2.sqlite")) == alteredBytes)
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
func freshSchemaAttestsCanonicalTransferJournalAndReopens() async throws {
    let root = temporaryStoreRoot("canonical-transfer-journal")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let databaseURL = await store.databaseURL
    #expect(try sqliteScalarInt(
        databaseURL: databaseURL,
        sql: "SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='upload_transfers'"
    ) == 1)
    #expect(try sqliteScalarInt(
        databaseURL: databaseURL,
        sql: "SELECT COUNT(*) FROM sqlite_schema WHERE type='index' AND name='upload_transfers_scope'"
    ) == 1)
    await store.close()
    _ = try LocalSyncV2Store(root: root, policy: .openExisting)
}

@Test
func unknownSchemaIsRejectedWithoutCatalogOrFileMutation() async throws {
    let root = temporaryStoreRoot("unknown-schema-no-mutation")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    await store.close()
    let databaseURL = root.appendingPathComponent("snapshot-sync-v2.sqlite")
    #expect(try sqliteExecutionSucceeded(
        databaseURL: databaseURL,
        sql: "CREATE TABLE unknown_schema_marker(value TEXT NOT NULL)"
    ))
    let beforeDatabase = try Data(contentsOf: databaseURL)
    do {
        _ = try LocalSyncV2Store(root: root, policy: .openExisting)
        Issue.record("unknown schema was accepted")
    } catch SyncV2StoreError.schemaMismatch {
        // Expected: attestation rejects before any additive DDL migration.
    }
    #expect(try Data(contentsOf: databaseURL) == beforeDatabase)
    #expect(try sqliteScalarInt(
        databaseURL: databaseURL,
        sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name='unknown_schema_marker'"
    ) == 1)
}

@Test
// swiftlint:disable:next function_body_length
func legacyRestoreStateMigratesPreparedAndSealedRowsWithoutDataLoss() async throws {
    let root = temporaryStoreRoot("legacy-restore-retirement")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let preparedWorkID = WorkID(UUID())
    let sealedWorkID = WorkID(UUID())
    var preparedDocument = makeDocument(title: "prepared")
    let preparedFirst = try await store.checkpoint(
        V2CheckpointRequest(
            workID: preparedWorkID,
            document: preparedDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    preparedDocument.title = "prepared newer"
    let preparedSecond = try await store.checkpoint(
        V2CheckpointRequest(
            workID: preparedWorkID,
            document: preparedDocument,
            documentCreatedAt: testDate,
            expectedGeneration: preparedFirst.generation
        ),
        scope: scopeA
    )
    _ = try await store.prepareRestore(
        V2RestorePreparationRequest(
            workID: preparedWorkID,
            selectedSnapshotID: preparedFirst.snapshotID,
            expectedLocalGeneration: preparedSecond.generation
        ),
        scope: scopeA
    )

    var sealedDocument = makeDocument(title: "sealed")
    let sealedFirst = try await store.checkpoint(
        V2CheckpointRequest(
            workID: sealedWorkID,
            document: sealedDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0
        ),
        scope: scopeA
    )
    sealedDocument.title = "sealed newer"
    let sealedSecond = try await store.checkpoint(
        V2CheckpointRequest(
            workID: sealedWorkID,
            document: sealedDocument,
            documentCreatedAt: testDate,
            expectedGeneration: sealedFirst.generation
        ),
        scope: scopeA
    )
    let sealedRestore = try await store.prepareRestore(
        V2RestorePreparationRequest(
            workID: sealedWorkID,
            selectedSnapshotID: sealedFirst.snapshotID,
            expectedLocalGeneration: sealedSecond.generation
        ),
        scope: scopeA
    )
    let sealedCommand = try restoreCommand(
        workID: sealedWorkID,
        source: sealedSecond,
        selected: sealedFirst.snapshotID,
        restored: sealedRestore
    )
    try await store.seal(
        sealedCommand,
        intentID: sealedRestore.checkpoint.intentID,
        scope: scopeA
    )

    let databaseURL = await store.databaseURL
    await store.close()
    let canonicalData = try SnapshotSyncV2SchemaContract.resourceSQL()
    let canonical = String(decoding: canonicalData, as: UTF8.self)
    let transferStart = try #require(canonical.range(of: "CREATE TABLE upload_transfers ("))
    let transferEnd = try #require(
        canonical.range(of: "CREATE TABLE remote_receipts (", range: transferStart.upperBound ..< canonical.endIndex)
    )
    let canonicalWithoutTransfer = String(canonical[..<transferStart.lowerBound]) +
        String(canonical[transferEnd.lowerBound...])
    let legacy = canonicalWithoutTransfer
        .replacingOccurrences(
            of: "state IN ('prepared', 'sealed', 'finalized', 'retired')",
            with: "state IN ('prepared', 'sealed', 'finalized')"
        )
        .replacingOccurrences(
            of: "state IN ('sealed', 'finalized', 'retired')",
            with: "state IN ('sealed', 'finalized')"
        )
        .replacingOccurrences(of: ") OR\n    state = 'retired'", with: ")")
    let restoreStart = try #require(legacy.range(of: "CREATE TABLE restore_records ("))
    let restoreEnd = try #require(
        legacy.range(of: "\nCREATE TABLE snapshot_remote_equivalents", range: restoreStart.upperBound ..< legacy.endIndex)
    )
    let legacyRestoreDDL = String(legacy[restoreStart.lowerBound ..< restoreEnd.lowerBound])
    let oldChecksum = SnapshotSyncV2SchemaContract.checksum(Data(legacy.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let rewrite = """
    BEGIN IMMEDIATE;
    ALTER TABLE restore_records RENAME TO restore_records_modern;
    \(legacyRestoreDDL)
    INSERT INTO restore_records(
      restore_id,work_id,account_id,selected_snapshot_id,pre_restore_snapshot_id,
      result_snapshot_id,intent_id,command_id,selected_remote_equivalent_snapshot_id,
      selected_remote_equivalent_generation,expected_remote_head_snapshot_id,
      expected_remote_head_generation,state
    ) SELECT restore_id,work_id,account_id,selected_snapshot_id,pre_restore_snapshot_id,
      result_snapshot_id,intent_id,command_id,selected_remote_equivalent_snapshot_id,
      selected_remote_equivalent_generation,expected_remote_head_snapshot_id,
      expected_remote_head_generation,state FROM restore_records_modern;
    DROP TABLE restore_records_modern;
    UPDATE schema_meta SET checksum=X'\(oldChecksum)' WHERE key='schema';
    COMMIT;
    """
    // The rewrite constructs an exact legacy v2 database while preserving all
    // rows; openExisting must then run the narrow, transactional upgrade.
    // Keep this direct execution separate from the actor so the old metadata
    // is present before openExisting performs attestation.
    guard try sqliteExecutionSucceeded(databaseURL: databaseURL, sql: rewrite) else {
        Issue.record("legacy schema rewrite failed")
        return
    }

    let migrated = try LocalSyncV2Store(root: root, policy: .openExisting)
    let schema = try await migrated.schemaVersionAndChecksum()
    #expect(schema.0 == SnapshotSyncV2SchemaContract.version)
    #expect(schema.1 == SnapshotSyncV2SchemaContract.checksum(Data(canonical.utf8)))
    let rotated = V2AccountBinding(
        accountID: bindingA.accountID,
        accountFence: "legacy-migrated-fence",
        serverInstanceID: bindingA.serverInstanceID
    )
    try await migrated.transitionAccountScopes(from: bindingA, to: rotated)
    do {
        let opened = try await migrated.open(workID: preparedWorkID, scope: .bound(rotated))
        #expect(opened.document?.title == "prepared")
    } catch {
        Issue.record("migrated head could not be opened: \(error)")
    }
    #expect(try sqliteScalarInt(
        databaseURL: databaseURL,
        sql: "SELECT COUNT(*) FROM restore_records WHERE state='retired'"
    ) == 2)
    #expect(try await migrated.pendingSealedCommands(scope: scopeA).isEmpty)
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
    let localEncoded = try encodeSnapshot(
        workID: sourceWorkID,
        document: fixture.localDocument,
        parents: [fixture.baseCheckpoint.snapshotID]
    )
    #expect(localEncoded.snapshotId == fixture.localCheckpoint.snapshotID)
    guard let objectID = localEncoded.objects.keys.first else {
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
