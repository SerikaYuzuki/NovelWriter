import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

extension ProductionRestartTests {
    @Test("a newer offline edit remains selectable without being overwritten")
    // The test deliberately spans the complete adoption and exact-replay
    // lifecycle so the restart boundary cannot be mocked by a unit helper.
    // swiftlint:disable:next function_body_length
    func newerEditKeepsConflictResolutionAvailable() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedProductionConflict(configuration: configuration)
        let publishGate = ProductionPublishGate()
        await installProductionResponder(
            configuration.remote,
            fixture: fixture,
            publishGate: publishGate
        )
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let conflict = try #require(
            await store.activeConflict(workID: fixture.workID, scope: productionScope)
        )
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let opened = try await app.open(workID: fixture.workID)
        _ = try await app.checkpoint(
            workID: fixture.workID,
            document: applicationTestDocument(
                id: #require(opened.document?.id),
                title: "追加入力",
                body: "競合後も保持"
            ),
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        let newerIntent = try #require(
            try await store.pendingIntents(scope: productionScope, workID: fixture.workID)
                .first(where: {
                    $0.kind == "checkpoint" && $0.sourceGeneration > fixture.sourceGeneration
                })
        )
        #expect(await app.uiState(workID: fixture.workID)?.remoteProgress == .needsChoice)
        let result = try await app.resolveConflict(
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
        #expect(result.typedResult == .queued)
        try await app.resumePending()
        try await eventually {
            try await app.pendingAdoption(workID: fixture.workID) != nil
        }
        let adoption = try #require(try await app.pendingAdoption(workID: fixture.workID))
        let session = await app.beginSession(workID: fixture.workID)
        let gate = try await app.documentGateToken(for: session)
        _ = try await app.applyStagedRemote(
            at: SafeAdoptionBoundary(
                workID: fixture.workID,
                inboxID: adoption.inboxID,
                session: session,
                gate: gate
            )
        )
        #expect(try await app.open(workID: fixture.workID).document?.title == "追加入力")
        #expect(await app.uiState(workID: fixture.workID)?.conflict == nil)
        #expect(
            try await store.historyPage(workID: fixture.workID, scope: productionScope)
                .items.contains { $0.snapshotID == fixture.localSnapshotID && $0.pinned }
        )
        try await eventually {
            try await LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
                .allSealedCommands(scope: productionScope, workID: fixture.workID)
                .contains {
                    $0.commandKind == "publish" &&
                        $0.intentID == newerIntent.intentID &&
                        $0.sourceSnapshotID == newerIntent.sourceSnapshotID &&
                        $0.sourceGeneration == newerIntent.sourceGeneration
                }
        }
        let sealedBeforeReplay = try #require(
            try await store.allSealedCommands(scope: productionScope, workID: fixture.workID)
                .first {
                    $0.commandKind == "publish" &&
                        $0.intentID == newerIntent.intentID &&
                        $0.sourceSnapshotID == newerIntent.sourceSnapshotID
                }
        )
        #expect([.sealed, .sending].contains(sealedBeforeReplay.lifecycle))
        try await eventually {
            await configuration.remote.recordedOperations()
                .compactMap(sealedCommand)
                .contains { $0.kind == .publish }
        }
        let operationsBeforeReplay = await configuration.remote.recordedOperations()
        let firstPublish = try #require(
            operationsBeforeReplay
                .compactMap(sealedCommand)
                .first { $0.kind == .publish }
        )
        #expect(firstPublish.command.commandId == sealedBeforeReplay.commandID)
        #expect(firstPublish.command.canonicalBytes == sealedBeforeReplay.canonicalRequest)

        let restarted = try await SnapshotSyncV2Runtime.makeApplicationForTesting(
            mode: .test(configuration),
            resumeOnLaunch: false
        )
        #expect(try await restarted.open(workID: fixture.workID).document?.title == "追加入力")
        let restartStore = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        #expect(
            try await restartStore.pendingIntents(scope: productionScope, workID: fixture.workID)
                .contains {
                    $0.intentID == newerIntent.intentID &&
                        $0.sourceSnapshotID == newerIntent.sourceSnapshotID &&
                        $0.sourceGeneration == newerIntent.sourceGeneration
                }
        )
        publishGate.allow()
        try await restarted.resumePending()
        try await eventually {
            try await LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
                .pendingIntents(scope: productionScope, workID: fixture.workID)
                .contains { $0.intentID == newerIntent.intentID } == false
        }
        let operationsAfterReplay = await configuration.remote.recordedOperations()
        let replay = try #require(
            operationsAfterReplay
                .compactMap(sealedCommand)
                .last {
                    $0.kind == .publish &&
                        $0.command.commandId == firstPublish.command.commandId
                }
        )
        #expect(replay.command.canonicalBytes == firstPublish.command.canonicalBytes)
        #expect(try await restarted.open(workID: fixture.workID).document?.title == "追加入力")
        #expect(await restarted.uiState(workID: fixture.workID)?.conflict == nil)
        let history = try await store.historyPage(workID: fixture.workID, scope: productionScope)
        #expect(history.items.contains { $0.snapshotID == fixture.localSnapshotID && $0.pinned })
    }
}
