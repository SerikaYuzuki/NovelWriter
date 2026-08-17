import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

@Suite("Snapshot Sync v2 production restart projections")
struct ProductionRestartTests {
    @Test("a clean production work projects as idle and duplicate delivery stays one conflict")
    func idleAndDuplicateConflictProjection() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedProductionConflict(configuration: configuration)
        await installProductionResponder(configuration.remote, fixture: fixture)
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let cleanID = WorkID(UUID())
        let clean = try encodedProductionSnapshot(
            workID: cleanID,
            title: "同期済み",
            body: "本文"
        )
        let cleanInbox = try V2RemoteSnapshot(
            workID: cleanID,
            encoded: clean,
            expectedCurrentSnapshotID: nil,
            expectedLocalGeneration: 0,
            expectedRemoteHead: V2RemoteHead(snapshotID: clean.snapshotId, generation: 1)
        )
        try await store.stageRemote(cleanInbox, scope: productionScope)
        try await store.verifyInbox(inboxID: cleanInbox.inboxID, scope: productionScope)
        try await store.adoptInbox(inboxID: cleanInbox.inboxID, scope: productionScope)

        let duplicate = V2RemoteSnapshot(
            inboxID: UUID(),
            workID: fixture.workID,
            encoded: fixture.remote,
            expectedCurrentSnapshotID: fixture.localSnapshotID,
            expectedLocalGeneration: fixture.sourceGeneration,
            expectedRemoteHead: fixture.remoteHead
        )
        try await store.stageRemote(duplicate, scope: productionScope)
        try await store.verifyInbox(inboxID: duplicate.inboxID, scope: productionScope)
        let first = try await store.activeConflict(workID: fixture.workID, scope: productionScope)
        let second = try await store.appendConflict(
            workID: fixture.workID,
            baseSnapshotID: fixture.baseSnapshotID,
            localSnapshotID: fixture.localSnapshotID,
            remote: duplicate,
            sourceGeneration: fixture.sourceGeneration,
            scope: productionScope
        )
        #expect(first?.conflictID == second.conflictID)
        #expect(first?.revision == second.revision)

        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let library = try await app.library()
        #expect(library.items.first(where: { $0.workID == cleanID })?.remoteProgress == .idle)
        #expect(library.items.count(where: { $0.workID == fixture.workID && $0.conflict != nil }) == 1)
    }

    @Test("production server choice seals resolveServer and never publish")
    // swiftlint:disable:next function_body_length
    func productionServerChoiceUsesResolutionCommand() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedProductionConflict(configuration: configuration)
        await installProductionResponder(configuration.remote, fixture: fixture)
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let conflict = try #require(
            await store.activeConflict(workID: fixture.workID, scope: productionScope)
        )
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        _ = try await app.open(workID: fixture.workID)
        let resolution = try await app.resolveConflict(
            workID: fixture.workID,
            action: SyncV2ConflictAction(
                workID: fixture.workID,
                conflictID: conflict.conflictID,
                revision: conflict.revision,
                baseSnapshotID: conflict.baseSnapshotID,
                localSnapshotID: conflict.localSnapshotID,
                remoteSnapshotID: conflict.remoteSnapshotID,
                sourceGeneration: conflict.sourceGeneration,
                choice: .useServer,
                inboxID: store.conflictInbox(conflict)
            )
        )
        #expect(resolution.typedResult == .queued)
        let pending = try await store.pendingIntents(scope: productionScope, workID: fixture.workID)
        #expect(pending.count == 1)
        #expect(pending.first?.kind == "conflictResolution")
        try await app.resumePending()
        try await Task.sleep(for: .milliseconds(50))
        try await app.resumePending()
        try await eventually {
            let operations = await configuration.remote.recordedOperations()
            let failed = await app.uiState(workID: fixture.workID)?.lastFailure != nil
            return operations.contains { commandKind($0) == .resolveServer } || failed
        }
        #expect(await app.uiState(workID: fixture.workID)?.lastFailure == nil)
        let operations = await configuration.remote.recordedOperations()
        #expect(operations.allSatisfy { commandKind($0) != .publish })
        try await eventually { try await app.pendingAdoption(workID: fixture.workID) != nil }
        let pendingAdoption = try #require(try await app.pendingAdoption(workID: fixture.workID))
        let session = await app.beginSession(workID: fixture.workID)
        let gate = try await app.documentGateToken(for: session)
        let adopted = try await app.applyStagedRemote(
            at: SafeAdoptionBoundary(
                workID: fixture.workID,
                inboxID: pendingAdoption.inboxID,
                session: session,
                gate: gate
            )
        )
        #expect(adopted.document?.title == "サーバー版")
        #expect(try await app.pendingAdoption(workID: fixture.workID) == nil)
        #expect(await app.uiState(workID: fixture.workID)?.conflict == nil)
        let history = try await store.historyPage(workID: fixture.workID, scope: productionScope)
        #expect(history.items.contains { $0.snapshotID == fixture.localSnapshotID && $0.pinned })
    }
}
