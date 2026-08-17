import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

extension ProductionRestartTests {
    // These integration scenarios intentionally keep the full production
    // command/restart sequence in one test for replay fidelity.
    // swiftlint:disable function_body_length

    @Test("production device choice never falls back to publish")
    func productionDeviceChoiceDoesNotPublish() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedProductionConflict(configuration: configuration)
        let publishGate = ProductionPublishGate()
        await installProductionResponder(configuration.remote, fixture: fixture, publishGate: publishGate)
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
                title: "端末追加入力",
                body: "解決中も保持"
            ),
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        let newerIntent = try #require(
            try await store.pendingIntents(scope: productionScope, workID: fixture.workID)
                .first(where: { $0.kind == "checkpoint" && $0.sourceGeneration > fixture.sourceGeneration })
        )
        #expect(try await store.allSealedCommands(scope: productionScope, workID: fixture.workID).allSatisfy {
            !($0.commandKind == "publish" && $0.sourceSnapshotID == newerIntent.sourceSnapshotID)
        })
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
                choice: .useDevice,
                inboxID: store.conflictInbox(conflict)
            )
        )
        #expect(resolution.typedResult == .queued)
        try await app.resumePending()
        try await eventually {
            let operations = await configuration.remote.recordedOperations()
            let failed = await app.uiState(workID: fixture.workID)?.lastFailure != nil
            return operations.contains { commandKind($0) == .resolveDevice } || failed
        }
        #expect(await app.uiState(workID: fixture.workID)?.lastFailure == nil)
        let operations = await configuration.remote.recordedOperations()
        #expect(operations.allSatisfy { commandKind($0) != .publish })
        #expect(operations.contains { commandKind($0) == .prepareObject })
        #expect(operations.contains { commandKind($0) == .registerSnapshot })
        try await eventually {
            let finalStore = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
            return try await finalStore.activeConflict(workID: fixture.workID, scope: productionScope) == nil
        }
        let resolvedStore = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let newerIntents = try await resolvedStore.pendingIntents(
            scope: productionScope,
            workID: fixture.workID
        )
        #expect(newerIntents.contains(newerIntent))
        let restarted = try await SnapshotSyncV2Runtime.makeApplicationForTesting(
            mode: .test(configuration),
            resumeOnLaunch: false
        )
        let reopened = try await restarted.open(workID: fixture.workID)
        #expect(reopened.document?.title == "端末追加入力")
        let restartStore = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let durableIntents = try await restartStore.pendingIntents(
            scope: productionScope,
            workID: fixture.workID
        )
        #expect(durableIntents.contains {
            $0.intentID == newerIntent.intentID &&
                $0.sourceSnapshotID == newerIntent.sourceSnapshotID &&
                $0.sourceGeneration == newerIntent.sourceGeneration &&
                $0.kind == newerIntent.kind
        })
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
        let durablePublish = try #require(
            try await restartStore.allSealedCommands(
                scope: productionScope,
                workID: fixture.workID
            ).first {
                $0.commandKind == "publish" &&
                    $0.intentID == newerIntent.intentID &&
                    $0.sourceSnapshotID == newerIntent.sourceSnapshotID &&
                    $0.sourceGeneration == newerIntent.sourceGeneration
            }
        )
        #expect([.sealed, .sending].contains(durablePublish.lifecycle))
        try await eventually {
            await configuration.remote.recordedOperations().contains {
                commandKind($0) == .publish
            }
        }
        let beforeReplay = await configuration.remote.recordedOperations()
        let firstPublish = try #require(
            beforeReplay
                .compactMap(sealedCommand)
                .first(where: { $0.kind == .publish })
        )
        #expect(firstPublish.command.commandId == durablePublish.commandID)
        #expect(firstPublish.command.canonicalBytes == durablePublish.canonicalRequest)
        publishGate.allow()
        try await restarted.resumePending()
        try await eventually {
            try await LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
                .pendingIntents(scope: productionScope, workID: fixture.workID)
                .contains { $0.intentID == newerIntent.intentID } == false
        }
        let afterReplay = await configuration.remote.recordedOperations()
        let replay = try #require(
            afterReplay
                .compactMap(sealedCommand)
                .last {
                    $0.kind == .publish &&
                        $0.command.commandId == firstPublish.command.commandId
                }
        )
        #expect(replay.command.canonicalBytes == firstPublish.command.canonicalBytes)
        #expect(try await restarted.open(workID: fixture.workID).document?.title == "端末追加入力")
        #expect(await restarted.uiState(workID: fixture.workID)?.conflict == nil)
    }

    @Test("production keep-both opens a second local work before transport")
    func productionKeepBothOpensCloneBeforeTransport() async throws {
        let configuration = try TestRuntimeConfiguration()
        let fixture = try await seedProductionConflict(configuration: configuration)
        let publishGate = ProductionPublishGate()
        await installProductionResponder(configuration.remote, fixture: fixture, publishGate: publishGate)
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
                title: "両方保持の追加入力",
                body: "後続編集"
            ),
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        let newerIntent = try #require(
            try await store.pendingIntents(scope: productionScope, workID: fixture.workID)
                .first(where: { $0.kind == "checkpoint" && $0.sourceGeneration > fixture.sourceGeneration })
        )
        #expect(try await store.allSealedCommands(scope: productionScope, workID: fixture.workID).allSatisfy {
            !($0.commandKind == "publish" && $0.sourceSnapshotID == newerIntent.sourceSnapshotID)
        })
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
                choice: .keepBoth,
                inboxID: store.conflictInbox(conflict)
            )
        )
        let clone = try #require(result.openedWork)
        #expect(clone.workID != fixture.workID)
        #expect(try await app.open(workID: clone.workID).document != nil)
        try await app.resumePending()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await app.uiState(workID: fixture.workID)?.lastFailure == nil)
        let earlyOperations = await configuration.remote.recordedOperations()
        #expect(!earlyOperations.isEmpty)
        try await eventually {
            let operations = await configuration.remote.recordedOperations()
            return operations.contains { commandKind($0) == .cloneWork }
        }
        let operations = await configuration.remote.recordedOperations()
        #expect(operations.contains { commandKind($0) == .cloneWork })
        #expect(operations.allSatisfy { commandKind($0) != .publish })
        let commandRecords = try await sourceStoreCommands(
            root: configuration.localRoot.url,
            workID: fixture.workID
        )
        #expect(commandRecords.first(where: { $0.commandKind == "cloneWork" })?.intentID != newerIntent.intentID)
        try await eventually {
            let finalStore = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
            return try await finalStore.activeConflict(workID: fixture.workID, scope: productionScope) == nil
        }
        #expect(try await app.open(workID: fixture.workID).document?.title == "両方保持の追加入力")
        #expect(try await app.open(workID: clone.workID).document?.title == "端末版")
        let restarted = try await SnapshotSyncV2Runtime.makeApplicationForTesting(
            mode: .test(configuration),
            resumeOnLaunch: false
        )
        #expect(try await restarted.open(workID: fixture.workID).document?.title == "両方保持の追加入力")
        #expect(try await restarted.open(workID: clone.workID).document?.title == "端末版")
        let sourceStore = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let sealedCommands = try await sourceStore.allSealedCommands(
            scope: productionScope,
            workID: fixture.workID
        )
        let newerPublish = try #require(sealedCommands.first {
            $0.commandKind == "publish" &&
                $0.sourceGeneration == newerIntent.sourceGeneration &&
                $0.sourceSnapshotID == newerIntent.sourceSnapshotID
        })
        #expect(newerPublish.intentID == newerIntent.intentID)
        #expect(newerPublish.lifecycle == .sealed)
        let durableIntent = try await sourceStore.pendingIntents(
            scope: productionScope,
            workID: fixture.workID
        )
        #expect(durableIntent.contains {
            $0.intentID == newerIntent.intentID &&
                $0.sourceSnapshotID == newerIntent.sourceSnapshotID &&
                $0.sourceGeneration == newerIntent.sourceGeneration &&
                $0.kind == newerIntent.kind
        })
        try await eventually {
            await configuration.remote.recordedOperations().contains {
                commandKind($0) == .publish
            }
        }
        let beforeReplay = await configuration.remote.recordedOperations()
        let firstPublish = try #require(
            beforeReplay
                .compactMap(sealedCommand)
                .first(where: { $0.kind == .publish })
        )
        #expect(firstPublish.command.commandId == newerPublish.commandID)
        #expect(firstPublish.command.canonicalBytes == newerPublish.canonicalRequest)
        publishGate.allow()
        try await restarted.resumePending()
        try await eventually {
            try await LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
                .pendingIntents(scope: productionScope, workID: fixture.workID)
                .contains { $0.intentID == newerIntent.intentID } == false
        }
        let afterReplay = await configuration.remote.recordedOperations()
        let replay = try #require(
            afterReplay
                .compactMap(sealedCommand)
                .last {
                    $0.kind == .publish &&
                        $0.command.commandId == firstPublish.command.commandId
                }
        )
        #expect(replay.command.canonicalBytes == firstPublish.command.canonicalBytes)
        #expect(try await restarted.open(workID: fixture.workID).document?.title == "両方保持の追加入力")
        #expect(try await restarted.open(workID: clone.workID).document?.title == "端末版")
        #expect(await restarted.uiState(workID: fixture.workID)?.conflict == nil)
    }

    // swiftlint:enable function_body_length
}
