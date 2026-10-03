import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite("One conflict has one resolution")
struct StoreMultipleResolutionTests {
    @Test(arguments: [SyncV2ConflictChoice.useDevice, .useServer, .keepBoth])
    func secondSelectionsAreRejected(first: SyncV2ConflictChoice) async throws {
        let root = temporaryStoreRoot("one-resolution")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let work = WorkID(UUID())
        let fixture = try await createConflict(store: store, workID: work)
        try await select(first, store: store, fixture: fixture)
        if first != .keepBoth {
            let history = try await store.history(workID: work, scope: scopeA)
            #expect(history.contains { $0.snapshotID == fixture.localCheckpoint.snapshotID && $0.pinned })
            #expect(history.contains { $0.snapshotID == fixture.remote.encoded.snapshotId && $0.pinned })
        }
        let before = try await store.open(workID: work, scope: scopeA)
        let intents = try await store.pendingIntents(scope: scopeA, workID: work)
        let works = try await store.listWorks(scope: scopeA)
        // A second connection proves rejection is durable, not an actor flag.
        let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
        for choice in [SyncV2ConflictChoice.useDevice, .useServer, .keepBoth] {
            await #expect(throws: SyncV2StoreError.staleConflictAction) {
                try await select(choice, store: reopened, fixture: fixture)
            }
        }
        #expect(try await reopened.open(workID: work, scope: scopeA).summary == before.summary)
        #expect(try await reopened.pendingIntents(scope: scopeA, workID: work) == intents)
        #expect(try await reopened.listWorks(scope: scopeA).count == works.count)
        #expect(intents.count(where: { $0.kind == "conflictResolution" }) == 1)
    }

    @Test("one unreadable work does not fail the shelf")
    func libraryFailureIsPerWork() async throws {
        let root = temporaryStoreRoot("shelf-one-bad-work")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let badWork = WorkID(UUID())
        let goodWork = WorkID(UUID())
        _ = try await store.checkpoint(V2CheckpointRequest(workID: badWork, document: makeDocument(title: "bad"),
                                                           documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit), scope: scopeA)
        _ = try await store.checkpoint(V2CheckpointRequest(workID: goodWork, document: makeDocument(title: "healthy"),
                                                           documentCreatedAt: testDate, expectedGeneration: 0, reason: .explicit), scope: scopeA)
        let databaseURL = await store.databaseURL
        #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL,
                                             sql: "UPDATE works SET document_id='00000000-0000-0000-0000-000000000000' WHERE work_id='\(badWork.description)'"))
        let kernel = ProductionSyncV2Kernel(store: store, scope: MultipleResolutionScope())
        let shelf = try await kernel.library()
        #expect(shelf.items.count == 2)
        #expect(shelf.items.first { $0.workID == goodWork }?.title == "healthy")
        #expect(shelf.items.first { $0.workID == badWork }?.remoteProgress == .failed(.invalidLocalState))
    }

    @Test("two Store connections cannot prepare different choices concurrently", arguments: [
        (SyncV2ConflictChoice.useDevice, SyncV2ConflictChoice.useServer),
        (.useServer, .keepBoth), (.keepBoth, .useDevice), (.useServer, .useServer)
    ])
    func competingTransactions(choices: (SyncV2ConflictChoice, SyncV2ConflictChoice)) async throws {
        let root = temporaryStoreRoot("resolution-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try LocalSyncV2Store(root: root, policy: .createNew)
        let work = WorkID(UUID())
        let fixture = try await createConflict(store: first, workID: work)
        let second = try LocalSyncV2Store(root: root, policy: .openExisting)
        async let device = attempt(choices.0, store: first, fixture: fixture)
        async let server = attempt(choices.1, store: second, fixture: fixture)
        let results = try await [device, server]
        #expect(results.count(where: { $0 }) == 1)
        #expect(try await first.pendingIntents(scope: scopeA, workID: work).count(where: { $0.kind == "conflictResolution" }) == 1)
    }

    @Test("server choice adopts the remote version and retains the local version")
    func serverChoicePreservesHistory() async throws {
        let root = temporaryStoreRoot("single-server-resolution")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let work = WorkID(UUID())
        let fixture = try await createConflict(store: store, workID: work)
        let request = serverRequest(fixture)
        let prepared = try await store.prepareUseServer(request, scope: scopeA)
        let command = try resolveServerCommand(workID: work, conflict: fixture.conflict)
        try await store.seal(command, intentID: prepared.intentID, scope: scopeA)
        try await store.acknowledge(commandAcknowledgement(command, head: fixture.remoteHead), scope: scopeA)
        let adopted = try await store.adoptPendingServerResolution(workID: work, inboxID: fixture.remote.inboxID, scope: scopeA)
        #expect(adopted.document?.title == "remote")
        let history = try await store.history(workID: work, scope: scopeA)
        #expect(history.contains { $0.snapshotID == fixture.localCheckpoint.snapshotID && $0.pinned })
        #expect(history.contains { $0.snapshotID == fixture.remote.encoded.snapshotId })
        #expect(try await store.snapshotDocument(workID: work, snapshotID: fixture.localCheckpoint.snapshotID, scope: scopeA).title == "local")
    }

    @Test("recovery excludes incomplete evidence and sealed decisions", arguments: ["unfinalized", "differentAccount", "noVerifiedInbox", "singleParent", "sealed"])
    func conservativeRepairRequiresExactEvidence(variant: String) async throws {
        let root = temporaryStoreRoot("recovery-excluded")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let work = WorkID(UUID())
        let legacy = try await legacyMultipleResolution(store: store, work: work, bothParents: variant != "singleParent")
        let databaseURL = await store.databaseURL
        switch variant {
        case "unfinalized":
            #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL,
                                                 sql: "UPDATE pending_keep_both SET state='sealed' WHERE source_work_id='\(work.description)'"))
        case "differentAccount":
            #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL,
                                                 sql: "UPDATE account_bindings SET state='parked' WHERE work_id='\(work.description)'"))
        case "noVerifiedInbox":
            #expect(try sqliteExecutionSucceeded(databaseURL: databaseURL,
                                                 sql: "UPDATE inbox_batches SET state='rejected' WHERE inbox_id='\(legacy.orphan.inboxID.uuidString.lowercased())'"))
        case "sealed":
            let checkpoint = V2CheckpointResult(snapshotID: legacy.decision.snapshotId,
                                                generation: legacy.fixture.conflict.sourceGeneration + 1,
                                                intentID: legacy.extraID, noChanges: false)
            let command = try resolveDeviceCommand(workID: work, conflict: legacy.fixture.conflict,
                                                   decision: checkpoint, expectedHead: legacy.fixture.remoteHead)
            try await store.seedLegacySealedDecision(command, intentID: legacy.extraID, work: work)
        default: break
        }
        await store.close()
        let reopened = try LocalSyncV2Store(root: root, policy: .openExisting)
        #expect(try await !reopened.hasRecoveredMultipleResolution(workID: work, scope: scopeA))
        #expect(try sqliteScalarInt(databaseURL: databaseURL,
                                    sql: "SELECT COUNT(*) FROM sync_intents WHERE intent_id='\(legacy.extraID.uuidString.lowercased())' AND status IN ('pending','sealed')") == 1)
    }

    @Test("explicit history restore releases the hold without publishing the extra decision")
    func repairCanBeResolvedByRestore() async throws {
        let root = temporaryStoreRoot("recovery-history-restore")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let work = WorkID(UUID())
        let legacy = try await legacyMultipleResolution(store: store, work: work)
        await store.close()
        let repaired = try LocalSyncV2Store(root: root, policy: .openExisting)
        let selected = legacy.fixture.remote.encoded.snapshotId
        let prepared = try await repaired.prepareRestore(
            V2RestorePreparationRequest(workID: work, selectedSnapshotID: selected,
                                        expectedLocalGeneration: legacy.fixture.conflict.sourceGeneration + 1), scope: scopeA
        )
        #expect(try await repaired.open(workID: work, scope: scopeA).document?.title == "remote")
        #expect(try await !repaired.hasRecoveredMultipleResolution(workID: work, scope: scopeA))
        let pending = try await repaired.pendingIntents(scope: scopeA, workID: work)
        #expect(pending.count == 1)
        #expect(pending.first?.kind == "restore")
        #expect(pending.first?.sourceSnapshotID == prepared.checkpoint.snapshotID)
        #expect(pending.first?.sourceSnapshotID != legacy.decision.snapshotId)
        #expect(try await repaired.pendingServerAdoption(workID: work, scope: scopeA) == nil)
    }

    @Test("extra legacy decision is held once; explicit adoption preserves every snapshot and clone")
    func conservativeRepair() async throws {
        let root = temporaryStoreRoot("multiple-resolution-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let work = WorkID(UUID())
        let legacy = try await legacyMultipleResolution(store: store, work: work)
        let fixture = legacy.fixture
        let cloneID = legacy.cloneID
        let cloneBefore = try await store.open(workID: cloneID, scope: scopeA)
        let orphan = legacy.orphan
        let decision = legacy.decision
        let extraID = legacy.extraID
        #expect(try await store.pendingIntents(scope: scopeA, workID: work).contains { $0.intentID == extraID })
        let databaseURL = await store.databaseURL
        let snapshots = try sqliteScalarInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM snapshots")
        let objects = try sqliteScalarInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM objects")
        await store.close()
        let repaired = try LocalSyncV2Store(root: root, policy: .openExisting)
        #expect(try await repaired.pendingIntents(scope: scopeA, workID: work).isEmpty)
        let pending = try #require(try await repaired.pendingServerAdoption(workID: work, scope: scopeA))
        #expect(pending.requiresExplicitConfirmation)
        #expect(pending.inboxID == orphan.inboxID)
        #expect(try await repaired.open(workID: work, scope: scopeA).summary.currentSnapshotID == decision.snapshotId)
        try await repaired.requestSynchronization(workID: work, scope: scopeA)
        #expect(try await repaired.pendingIntents(scope: scopeA, workID: work).isEmpty)
        let planner = ProductionSyncV2Planner(store: repaired, scope: MultipleResolutionScope())
        if case .idle = try await planner.nextCommand(workID: work) {} else {
            Issue.record("repaired decision was planned for transmission")
        }
        let count = try await repaired.historyCount(workID: work, scope: scopeA)
        await repaired.close()
        let restarted = try LocalSyncV2Store(root: root, policy: .openExisting)
        #expect(try await restarted.historyCount(workID: work, scope: scopeA) == count)
        let adopted = try await restarted.adoptPendingServerResolution(workID: work, inboxID: pending.inboxID, scope: scopeA)
        #expect(adopted.document?.title == "remote")
        #expect(try await restarted.pendingServerAdoption(workID: work, scope: scopeA) == nil)
        #expect(try await restarted.open(workID: cloneID, scope: scopeA).summary == cloneBefore.summary)
        #expect(try sqliteScalarInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM snapshots") == snapshots)
        #expect(try sqliteScalarInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM objects") == objects)
        let history = try await restarted.history(workID: work, scope: scopeA)
        for snapshot in [decision.snapshotId, fixture.localCheckpoint.snapshotID, fixture.remote.encoded.snapshotId] {
            #expect(history.contains { $0.snapshotID == snapshot })
            #expect(try await restarted.snapshotDocument(workID: work, snapshotID: snapshot, scope: scopeA).id == fixture.localDocument.id)
        }
        #expect(try sqliteScalarInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM sync_intents WHERE intent_id='\(extraID.uuidString.lowercased())' AND status='parked'") == 1)
    }
}

private struct MultipleResolutionScope: SyncV2ScopeResolver {
    func activeBinding() async throws -> V2AccountBinding? {
        bindingA
    }

    func existingScope(workID _: WorkID) async throws -> V2LocalWorkScope {
        scopeA
    }

    func scopeForCheckpoint(workID _: WorkID) async throws -> V2LocalWorkScope {
        scopeA
    }
}

private func attempt(_ choice: SyncV2ConflictChoice, store: LocalSyncV2Store, fixture: ConflictFixture) async throws -> Bool {
    do { try await select(choice, store: store, fixture: fixture); return true }
    catch SyncV2StoreError.staleConflictAction { return false }
}

private func select(_ choice: SyncV2ConflictChoice, store: LocalSyncV2Store, fixture: ConflictFixture) async throws {
    let conflict = fixture.conflict
    switch choice {
    case .useDevice:
        _ = try await store.prepareUseDevice(V2DeviceResolutionRequest(workID: conflict.workID, conflictID: conflict.conflictID,
                                                                       revision: conflict.revision, sourceGeneration: conflict.sourceGeneration,
                                                                       localSnapshotID: conflict.localSnapshotID, remoteSnapshotID: conflict.remoteSnapshotID,
                                                                       inboxID: fixture.remote.inboxID, remoteHead: fixture.remoteHead), scope: scopeA)
    case .useServer:
        _ = try await store.prepareUseServer(serverRequest(fixture), scope: scopeA)
    case .keepBoth:
        _ = try await store.prepareKeepBothResolution(keepRequest(fixture, newWorkID: WorkID(UUID())), scope: scopeA)
    }
}

private func serverRequest(_ fixture: ConflictFixture) -> V2ServerResolutionRequest {
    let conflict = fixture.conflict
    return V2ServerResolutionRequest(workID: conflict.workID, conflictID: conflict.conflictID, revision: conflict.revision,
                                     sourceGeneration: conflict.sourceGeneration, localSnapshotID: conflict.localSnapshotID,
                                     remoteSnapshotID: conflict.remoteSnapshotID, inboxID: fixture.remote.inboxID,
                                     expectedRemoteHead: fixture.remoteHead)
}

private func keepRequest(_ fixture: ConflictFixture, newWorkID: WorkID) -> V2KeepBothPreparationRequest {
    let conflict = fixture.conflict
    return V2KeepBothPreparationRequest(workID: conflict.workID, conflictID: conflict.conflictID, revision: conflict.revision,
                                        sourceGeneration: conflict.sourceGeneration, localSnapshotID: conflict.localSnapshotID,
                                        remoteSnapshotID: conflict.remoteSnapshotID, newWorkID: newWorkID, newDocumentID: DocumentID(UUID()))
}

private extension LocalSyncV2Store {
    func snapshotDocument(workID: WorkID, snapshotID: SnapshotID, scope: V2LocalWorkScope) throws -> NovelDocument {
        let encoded = try #require(try committedSnapshot(workID: workID, snapshotID: snapshotID, scope: scope))
        return try SnapshotCodec.decode(manifestBytes: encoded.manifestBytes, objects: encoded.objects).document
    }

    func seedLegacySealedDecision(_ command: SealedCommand, intentID: UUID, work: WorkID) throws {
        try inTransaction {
            try outboxRepository.insertSealedCommand(command, workID: work, binding: bindingA, intentID: intentID)
        }
    }

    func seedLegacyExtraDecision(_ decision: EncodedSnapshot, fixture: ConflictFixture) throws -> UUID {
        try inTransaction {
            let work = fixture.conflict.workID
            let generation = fixture.conflict.sourceGeneration + 1
            try workRepository.insertEncoded(decision, workID: work)
            try exec("UPDATE works SET current_snapshot_id=?,local_generation=? WHERE work_id=?",
                     [.blob(decision.snapshotIDBytes), .int(generation), .text(work.description)])
            try workRepository.insertHistory(workID: work, snapshotID: decision.snapshotId, reason: "conflictResolution", pinned: false, generation: generation)
            let id = UUID()
            try outboxRepository.insertIntent(.init(intentID: id, workID: work, snapshotID: decision.snapshotId,
                                                    generation: generation, kind: "conflictResolution", scope: scopeA))
            return id
        }
    }
}

private struct LegacyMultipleResolution {
    let fixture: ConflictFixture
    let cloneID: WorkID
    let orphan: V2RemoteSnapshot
    let decision: EncodedSnapshot
    let extraID: UUID
}

private func legacyMultipleResolution(store: LocalSyncV2Store, work: WorkID, bothParents: Bool = true) async throws -> LegacyMultipleResolution {
    let fixture = try await createConflict(store: store, workID: work)
    let cloneID = WorkID(UUID())
    let prepared = try await store.prepareKeepBothResolution(keepRequest(fixture, newWorkID: cloneID), scope: scopeA)
    let command = try cloneWorkCommand(conflict: fixture.conflict, reservation: prepared.reservation, expectedHead: fixture.remoteHead)
    try await store.seal(command, intentID: prepared.intentID, scope: scopeA)
    try await store.acknowledge(commandAcknowledgement(command, head: V2RemoteHead(snapshotID: prepared.reservation.newRootSnapshotID, generation: 1)), scope: scopeA)
    // Old clients left a separate verified delivery of the same remote head.
    let orphan = V2RemoteSnapshot(workID: work, encoded: fixture.remote.encoded,
                                  expectedCurrentSnapshotID: fixture.baseCheckpoint.snapshotID,
                                  expectedLocalGeneration: fixture.baseCheckpoint.generation,
                                  expectedRemoteHead: fixture.remoteHead)
    try await store.stageRemote(orphan, scope: scopeA)
    try await store.verifyInbox(inboxID: orphan.inboxID, scope: scopeA)
    let parents = bothParents
        ? [fixture.conflict.localSnapshotID, fixture.conflict.remoteSnapshotID].sorted { $0.rawValue < $1.rawValue }
        : [fixture.conflict.localSnapshotID]
    let decision = try encodeSnapshot(workID: work, document: fixture.localDocument, parents: parents)
    let extraID = try await store.seedLegacyExtraDecision(decision, fixture: fixture)
    return LegacyMultipleResolution(fixture: fixture, cloneID: cloneID, orphan: orphan, decision: decision, extraID: extraID)
}
