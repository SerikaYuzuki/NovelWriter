import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

struct AncestorReceiptAdoptionTests {
    @Test(arguments: [false, true])
    func redundantPublishThenOpenAndAdopt(repairLegacyStore: Bool) async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedAncestorPublish(configuration: configuration)
        let store = fixture.store
        let app = try await SnapshotSyncV2Runtime.makeApplicationForTesting(
            mode: .test(configuration),
            resumeOnLaunch: false
        )
        let redundant = fixture.redundant
        let inbox = fixture.inbox
        let head = try V2RemoteHead(snapshotID: inbox.headSnapshotID, generation: 842)
        await configuration.remote.setCommandHandler { planned in
            guard planned.command.commandId == redundant.commandId else { throw SyncV2Failure.receiptMismatch }
            let response = try productionResponse(command: planned.command, result: .noChanges,
                                                  head: head, cloneHead: nil, status: 200)
            let envelope = try productionEnvelope(
                command: planned.command,
                response: response,
                result: .noChanges,
                status: 200
            )
            return .command(receipt: SyncV2ReceiptReadback(
                commandID: planned.command.commandId, requestDigest: planned.command.requestDigest,
                responseStatus: 200, canonicalResponse: envelope,
                predicates: .init(accountMatched: true, commandDigestMatched: true, resourceMatched: true,
                                  headMatched: true, stateMatched: true),
                result: .noChanges, remoteHead: inbox.expectedRemoteHead
            ), remoteInbox: inbox)
        }
        try await app.resumePending()
        try await eventually { try await app.pendingAdoption(workID: fixture.workID) != nil }
        #expect(try await store.query("SELECT remote_generation FROM snapshot_remote_equivalents").first?[0]
            .int64 == 839)
        let openingApp: SyncV2Application
        if repairLegacyStore {
            try await fixture.corruptLegacyEquivalence()
            openingApp = try await SnapshotSyncV2Runtime.makeApplicationForTesting(
                mode: .test(configuration),
                resumeOnLaunch: false
            )
        } else {
            openingApp = app
        }
        let opened = try await openingApp.openLocal(workID: fixture.workID)
        #expect(opened.snapshotID == fixture.local.snapshotID)
        #expect(opened.generation == 1467)
        #expect(await openingApp.uiState(workID: fixture.workID)?.conflict == nil)
        let pending = try #require(await openingApp.pendingAdoption(workID: fixture.workID))
        let session = await openingApp.beginSession(workID: fixture.workID)
        let token = try await openingApp.documentGateToken(for: session)
        let adopted = try await openingApp.applyStagedRemote(at: SafeAdoptionBoundary(
            workID: fixture.workID, inboxID: pending.inboxID, session: session, gate: token
        ))
        #expect(adopted.snapshotID == inbox.headSnapshotID)
        #expect(adopted.document?.title == "iPhone 842")
        #expect(adopted.generation == 1468)
        #expect(adopted.attachments == [fixture.cover])
        #expect(adopted.attachments.first?.bytes.count == 202_375)
        #expect(try await store.pendingIntents(scope: productionScope).isEmpty)
        #expect(try await openingApp.pendingAdoption(workID: fixture.workID) == nil)
        #expect(try await store.query("SELECT remote_snapshot_id,remote_generation FROM snapshot_remote_equivalents")
            .first?[0].blob == fixture.local.snapshotID.bytes)
        #expect(try await store.query("SELECT remote_generation FROM snapshot_remote_equivalents").first?[0]
            .int64 == 839)
        #expect(try await store.open(workID: fixture.workID, scope: productionScope).attachments == [fixture.cover])
        await store.close()
    }
}

private struct AncestorPublishFixture {
    let store: LocalSyncV2Store
    let workID: WorkID
    let local: V2CheckpointResult
    let redundant: SealedCommand
    let inbox: SyncV2RemoteInbox
    let cover: SyncAttachment
}

private extension AncestorPublishFixture {
    func corruptLegacyEquivalence() async throws {
        // Reproduce the old ON CONFLICT overwrite before the normal opener migrates it.
        try await store.exec("UPDATE snapshot_remote_equivalents SET remote_snapshot_id=?,remote_generation=842",
                             [.blob(inbox.headSnapshotID.bytes)])
        let sql = try String(decoding: SnapshotSyncV2SchemaContract.resourceSQL(), as: UTF8.self)
        let old = Data(sql.components(separatedBy: "\n-- Receipt equivalence repair (D-108).")[0].utf8)
        try await store.exec("UPDATE schema_meta SET checksum=? WHERE key='schema'",
                             [.blob(SnapshotSyncV2SchemaContract.checksum(old))])
    }
}

private func seedAncestorPublish(configuration: TestRuntimeConfiguration,
                                 sealRedundant: Bool = true) async throws -> AncestorPublishFixture {
    let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .createNew)
    let workID = WorkID(UUID())
    var document = applicationTestDocument(title: "Mac C")
    let initial = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: document, documentCreatedAt: applicationTestCreatedAt,
        expectedGeneration: 0, reason: .explicit
    ), scope: productionScope)
    try await store.exec("UPDATE works SET local_generation=1467 WHERE work_id=?", [.text(workID.description)])
    try await store.exec("UPDATE sync_intents SET source_generation=1467 WHERE work_id=?", [.text(workID.description)])
    try await store.insertHistory(
        workID: workID,
        snapshotID: initial.snapshotID,
        reason: "explicit",
        pinned: true,
        generation: 1467
    )
    let local = V2CheckpointResult(
        snapshotID: initial.snapshotID,
        generation: 1467,
        intentID: initial.intentID,
        noChanges: false
    )
    let first = try productionPublishCommand(workID: workID, checkpoint: local, expectedHead: nil)
    try await store.seal(first, intentID: local.intentID, scope: productionScope)
    let initialHead = try V2RemoteHead(snapshotID: local.snapshotID, generation: 839)
    try await store.acknowledge(
        productionAcknowledgement(first, result: .applied, status: 200, head: initialHead),
        scope: productionScope
    )
    var snapshots = try await [store.loadEncoded(workID: workID, snapshotID: local.snapshotID)]
    let cover = SyncAttachment(attachmentId: UUID(), fileName: "cover.jpg", bytes: Data(repeating: 42, count: 202_375))
    for generation in 840 ... 842 {
        document.title = "iPhone \(generation)"
        let encoded = try SnapshotCodec.encode(SnapshotModel(
            workId: workID, document: document, documentCreatedAt: applicationTestCreatedAt,
            attachments: generation == 842 ? [cover] : []
        ), parents: [#require(snapshots.last).snapshotId])
        snapshots.append(encoded)
    }
    // Stale old-client intent, even though C was already received at 839.
    let intentID = UUID()
    if sealRedundant {
        try await store.insertIntent(intentID: intentID, workID: workID, snapshotID: local.snapshotID,
                                     generation: local.generation, kind: "checkpoint", scope: productionScope)
    }
    let redundant = try productionPublishCommand(workID: workID, checkpoint: local, expectedHead: initialHead)
    if sealRedundant {
        try await store.seal(redundant, intentID: intentID, scope: productionScope)
    }
    let head = try #require(snapshots.last).snapshotId
    let inbox = try SyncV2RemoteInbox(
        inboxID: UUID(), workID: workID, headSnapshotID: head, snapshots: snapshots,
        expectedCurrentSnapshotID: local.snapshotID, expectedLocalGeneration: 1467,
        expectedRemoteHead: SyncV2RemoteHead(snapshotID: head, generation: 842)
    )
    return AncestorPublishFixture(
        store: store,
        workID: workID,
        local: local,
        redundant: redundant,
        inbox: inbox,
        cover: cover
    )
}

extension AncestorReceiptAdoptionTests {
    @Test(arguments: [false, true])
    func cleanRemoteCheckReadsWithoutPublishing(concurrentEdit: Bool) async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedAncestorPublish(configuration: configuration, sealRedundant: false)
        let app = try await SnapshotSyncV2Runtime.makeApplicationForTesting(
            mode: .test(configuration),
            resumeOnLaunch: false
        )
        let inbox = fixture.inbox
        await configuration.remote.setHeadHandler { _ in inbox.expectedRemoteHead }
        await configuration.remote.setUpdateHandler { _ in
            if concurrentEdit {
                let opened = try await fixture.store.open(workID: fixture.workID, scope: productionScope)
                var document = try #require(opened.document)
                document.title = "保存したローカル編集"
                _ = try await fixture.store.checkpoint(V2CheckpointRequest(
                    workID: fixture.workID, document: document, documentCreatedAt: applicationTestCreatedAt,
                    expectedGeneration: 1467, reason: .autosave
                ), scope: productionScope)
            }
            return inbox
        }
        #expect(try await app.checkForRemoteUpdates(workID: fixture.workID) == !concurrentEdit)
        #expect(await configuration.remote.recordedOperations().isEmpty)
        #expect(try await fixture.store.query("SELECT COUNT(*) FROM sync_intents").first?[0].int64 == 1)
        #expect(try await fixture.store.pendingIntents(scope: productionScope).isEmpty)
        if concurrentEdit {
            #expect(try await app.pendingAdoption(workID: fixture.workID) == nil)
            #expect(try await fixture.store.open(workID: fixture.workID, scope: productionScope).document?
                .title == "保存したローカル編集")
        } else {
            let pending = try #require(await app.pendingAdoption(workID: fixture.workID))
            let session = await app.beginSession(workID: fixture.workID)
            let gate = try await app.documentGateToken(for: session)
            let adopted = try await app.applyStagedRemote(at: .init(
                workID: fixture.workID,
                inboxID: pending.inboxID,
                session: session,
                gate: gate
            ))
            #expect(adopted.snapshotID == inbox.headSnapshotID)
            #expect(adopted.attachments == [fixture.cover])
            #expect(await configuration.remote.recordedOperations().isEmpty)
        }
        await fixture.store.close()
    }
}

extension AncestorReceiptAdoptionTests {
    @Test func downloadedUpdateCannotCrossAccountFence() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedAncestorPublish(configuration: configuration, sealRedundant: false)
        let app = try await SnapshotSyncV2Runtime.makeApplicationForTesting(
            mode: .test(configuration),
            resumeOnLaunch: false
        )
        let inbox = fixture.inbox
        await configuration.remote.setHeadHandler { _ in inbox.expectedRemoteHead }
        await configuration.remote.setUpdateHandler { _ in
            SyncV2RemoteInbox(inboxID: inbox.inboxID, workID: inbox.workID,
                              headSnapshotID: inbox.headSnapshotID, snapshots: inbox.snapshots,
                              expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                              expectedRemoteHead: inbox.expectedRemoteHead,
                              binding: .init(accountFence: "another-fence", accountId: productionBinding.accountID,
                                             protocolEpoch: 2, serverInstanceId: productionBinding.serverInstanceID))
        }
        await #expect(throws: SyncV2Failure.accountFenceChanged) {
            try await app.checkForRemoteUpdates(workID: fixture.workID)
        }
        #expect(try await fixture.store.query("SELECT COUNT(*) FROM inbox_batches").first?[0].int64 == 0)
        #expect(try await fixture.store.workSummary(workID: fixture.workID, scope: productionScope)
            .acknowledgedHeadGeneration == 839)
        #expect(await configuration.remote.recordedOperations().isEmpty)
        await fixture.store.close()
    }
}
