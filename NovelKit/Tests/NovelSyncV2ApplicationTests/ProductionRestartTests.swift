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

private func sourceStoreCommands(
    root: URL,
    workID: WorkID
) async throws -> [V2SealedCommandRecord] {
    let store = try LocalSyncV2Store(root: root, policy: .openExisting)
    return try await store.allSealedCommands(scope: productionScope, workID: workID)
}

private func sealedCommand(
    _ operation: SyncV2RemoteOperation
) -> SyncV2SealedRemoteCommand? {
    guard case let .command(command) = operation else { return nil }
    return command
}

let productionScope = V2LocalWorkScope.bound(
    V2AccountBinding(
        accountID: "test-account",
        accountFence: "test-fence",
        serverInstanceID: "test-server"
    )
)

private let productionBinding = V2AccountBinding(
    accountID: "test-account",
    accountFence: "test-fence",
    serverInstanceID: "test-server"
)

struct ProductionConflictFixture {
    let workID: WorkID
    let baseSnapshotID: SnapshotID
    let localSnapshotID: SnapshotID
    let sourceGeneration: Int64
    let remote: EncodedSnapshot
    let remoteHead: V2RemoteHead
}

func seedProductionConflict(
    configuration: TestRuntimeConfiguration
) async throws -> ProductionConflictFixture {
    let store = try LocalSyncV2Store(
        root: configuration.localRoot.url,
        policy: .createNew
    )
    let workID = WorkID(UUID())
    let documentID = UUID()
    let base = try encodedProductionSnapshot(
        workID: workID,
        documentID: documentID,
        title: "基準",
        body: "基準"
    )
    let baseInbox = try V2RemoteSnapshot(
        workID: workID,
        encoded: base,
        expectedCurrentSnapshotID: nil,
        expectedLocalGeneration: 0,
        expectedRemoteHead: V2RemoteHead(snapshotID: base.snapshotId, generation: 1)
    )
    try await store.stageRemote(baseInbox, scope: productionScope)
    try await store.verifyInbox(inboxID: baseInbox.inboxID, scope: productionScope)
    try await store.adoptInbox(inboxID: baseInbox.inboxID, scope: productionScope)

    let localDocument = applicationTestDocument(id: documentID, title: "端末版", body: "端末")
    let localResult = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: localDocument,
            documentCreatedAt: applicationTestCreatedAt,
            expectedGeneration: 1,
            reason: .autosave
        ),
        scope: productionScope
    )
    let publish = try productionPublishCommand(
        workID: workID,
        checkpoint: localResult,
        expectedHead: V2RemoteHead(snapshotID: base.snapshotId, generation: 1)
    )
    try await store.seal(publish, intentID: localResult.intentID, scope: productionScope)

    let remote = try SnapshotCodec.encode(
        SnapshotModel(
            workId: workID,
            document: applicationTestDocument(id: documentID, title: "サーバー版", body: "サーバー"),
            documentCreatedAt: applicationTestCreatedAt
        ),
        parents: [base.snapshotId]
    )
    let remoteHead = try V2RemoteHead(snapshotID: remote.snapshotId, generation: 3)
    let conflictDelivery = V2RemoteSnapshot(
        inboxID: UUID(),
        workID: workID,
        encoded: remote,
        expectedCurrentSnapshotID: localResult.snapshotID,
        expectedLocalGeneration: 2,
        expectedRemoteHead: remoteHead
    )
    let blockedReceipt = try productionAcknowledgement(
        publish,
        result: .conflictPending,
        status: 409,
        head: remoteHead
    )
    try await store.acknowledge(blockedReceipt, scope: productionScope)
    _ = try await store.appendConflict(
        workID: workID,
        baseSnapshotID: base.snapshotId,
        localSnapshotID: localResult.snapshotID,
        remote: conflictDelivery,
        sourceGeneration: 2,
        scope: productionScope
    )
    return ProductionConflictFixture(
        workID: workID,
        baseSnapshotID: base.snapshotId,
        localSnapshotID: localResult.snapshotID,
        sourceGeneration: 2,
        remote: remote,
        remoteHead: remoteHead
    )
}

func encodedProductionSnapshot(
    workID: WorkID,
    documentID: UUID = UUID(),
    title: String,
    body: String
) throws -> EncodedSnapshot {
    try SnapshotCodec.encode(
        SnapshotModel(
            workId: workID,
            document: applicationTestDocument(id: documentID, title: title, body: body),
            documentCreatedAt: applicationTestCreatedAt
        ),
        parents: []
    )
}

private final class ProductionPublishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    func allow() {
        lock.lock(); defer { lock.unlock() }
        enabled = true
    }

    func isAllowed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }
}

private func installProductionResponder(
    _ remote: FakeSyncV2RemoteClient,
    fixture: ProductionConflictFixture,
    publishGate: ProductionPublishGate? = nil
) async {
    await remote.setCommandHandler { command in
        if command.kind == .publish, let publishGate, !publishGate.isAllowed() {
            throw SyncV2Failure.offline
        }
        return try productionExecution(command, fixture: fixture)
    }
}

func productionPublishCommand(
    workID: WorkID,
    checkpoint: V2CheckpointResult,
    expectedHead: V2RemoteHead
) throws -> SealedCommand {
    let envelope: [String: Any] = [
        "binding": [
            "accountFence": productionBinding.accountFence,
            "accountId": productionBinding.accountID,
            "protocolEpoch": productionBinding.protocolEpoch,
            "serverInstanceId": productionBinding.serverInstanceID
        ],
        "commandId": UUID().uuidString.lowercased(),
        "commandKind": "publish",
        "payload": [
            "candidateSnapshotId": checkpoint.snapshotID.rawValue,
            "expectedRemoteHead": productionHead(expectedHead),
            "workId": workID.description
        ],
        "schemaVersion": 2,
        "sourceGeneration": checkpoint.generation,
        "sourceSnapshotId": checkpoint.snapshotID.rawValue
    ]
    return try SealedCommand.decodeCanonical(productionJSON(envelope))
}

private func productionPayload(_ command: SealedCommand) throws -> [String: Any] {
    let object = try productionDictionary(command.canonicalBytes)
    guard let payload = object["payload"] as? [String: Any] else {
        throw SyncV2Failure.receiptMismatch
    }
    return payload
}

func productionExecution(
    _ command: SyncV2SealedRemoteCommand,
    fixture: ProductionConflictFixture
) throws -> SyncV2RemoteExecution {
    let kind = command.kind
    let payload = try productionPayload(command.command)
    let result: V2CommandTerminalResult = kind == .prepareObject ? .noChanges : .applied
    let status = kind == .createWork ? 201 : 200
    let head = try productionRemoteHead(kind: kind, payload: payload, fixture: fixture)
    let cloneHead = try productionCloneHead(kind: kind, payload: payload)
    let response = try productionResponse(
        command: command.command,
        result: result,
        head: head,
        cloneHead: cloneHead,
        status: status
    )
    let envelope = try productionEnvelope(
        command: command.command,
        response: response,
        result: result,
        status: status
    )
    let receipt = SyncV2ReceiptReadback(
        commandID: command.command.commandId,
        requestDigest: command.command.requestDigest,
        responseStatus: status,
        canonicalResponse: envelope,
        predicates: SyncV2ReadBackPredicates(
            accountMatched: true,
            commandDigestMatched: true,
            resourceMatched: true,
            headMatched: true,
            stateMatched: true
        ),
        result: .applied,
        remoteHead: head.flatMap { try? SyncV2RemoteHead(snapshotID: $0.snapshotID, generation: $0.generation) },
        cloneRemoteHead: cloneHead.flatMap { try? SyncV2RemoteHead(snapshotID: $0.snapshotID, generation: $0.generation) }
    )
    return .command(receipt: receipt, remoteInbox: nil)
}

private func productionRemoteHead(
    kind: SyncV2RemoteOperationKind,
    payload: [String: Any],
    fixture: ProductionConflictFixture
) throws -> V2RemoteHead? {
    switch kind {
    case .resolveServer, .cloneWork:
        return fixture.remoteHead
    case .resolveDevice:
        let decisionSnapshotID = try productionString(payload, key: "decisionSnapshotId")
        return try V2RemoteHead(
            snapshotID: SnapshotID(rawValue: decisionSnapshotID),
            generation: 4
        )
    case .publish:
        let candidate = try productionString(payload, key: "candidateSnapshotId")
        let expectedGeneration = (payload["expectedRemoteHead"] as? [String: Any])?["generation"] as? NSNumber
        return try V2RemoteHead(
            snapshotID: SnapshotID(rawValue: candidate),
            generation: (expectedGeneration?.int64Value ?? fixture.remoteHead.generation) + 1
        )
    default:
        return nil
    }
}

private func productionCloneHead(
    kind: SyncV2RemoteOperationKind,
    payload: [String: Any]
) throws -> V2RemoteHead? {
    guard kind == .cloneWork else { return nil }
    let newRootSnapshotID = try productionString(payload, key: "newRootSnapshotId")
    return try V2RemoteHead(
        snapshotID: SnapshotID(rawValue: newRootSnapshotID),
        generation: 1
    )
}

private func productionAcknowledgement(
    _ command: SealedCommand,
    result: V2CommandTerminalResult,
    status: Int,
    head: V2RemoteHead
) throws -> V2CommandAcknowledgement {
    let response = try productionResponse(
        command: command,
        result: result,
        head: head,
        cloneHead: nil,
        status: status
    )
    let readBack = productionReadBack()
    let payload = try productionPayload(command)
    let workKey = command.commandKind == "cloneWork" ? "sourceWorkId" : "workId"
    let workID = try productionString(payload, key: workKey)
    let envelope: [String: Any] = [
        "canonicalResponseBase64URL": response.base64URLEncodedString(),
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "originalResponseStatus": status,
        "originalResult": result.rawValue,
        "readBack": readBack,
        "requestDigest": command.requestDigest.rawValue,
        "result": "noChanges",
        "workId": workID
    ]
    return try V2CommandAcknowledgement(
        commandID: command.commandId,
        canonicalReceiptEnvelope: productionJSON(envelope)
    )
}

private func productionEnvelope(
    command: SealedCommand,
    response: Data,
    result: V2CommandTerminalResult,
    status: Int
) throws -> Data {
    let payload = try productionPayload(command)
    let workKey = command.commandKind == "cloneWork" ? "sourceWorkId" : "workId"
    let workID = try productionString(payload, key: workKey)
    let envelope: [String: Any] = [
        "canonicalResponseBase64URL": response.base64URLEncodedString(),
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "originalResponseStatus": status,
        "originalResult": result.rawValue,
        "readBack": productionReadBack(),
        "requestDigest": command.requestDigest.rawValue,
        "result": "noChanges",
        "workId": workID
    ]
    return try productionJSON(envelope)
}

private func productionReadBack() -> [String: Any] {
    [
        "accountMatched": true,
        "commandDigestMatched": true,
        "headMatched": true,
        "resourceMatched": true,
        "stateMatched": true
    ]
}

private func productionDictionary(_ data: Data) throws -> [String: Any] {
    guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SyncV2Failure.receiptMismatch
    }
    return dictionary
}

private func productionString(_ dictionary: [String: Any], key: String) throws -> String {
    guard let value = dictionary[key] as? String else {
        throw SyncV2Failure.receiptMismatch
    }
    return value
}

private func productionResponse(
    command: SealedCommand,
    result: V2CommandTerminalResult,
    head: V2RemoteHead?,
    cloneHead: V2RemoteHead?,
    status _: Int
) throws -> Data {
    let payload = try productionPayload(command)
    let workKey = command.commandKind == "cloneWork" ? "sourceWorkId" : "workId"
    let workID = try productionString(payload, key: workKey)
    let receipt: [String: Any] = [
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "readBack": productionReadBack(),
        "requestDigest": command.requestDigest.rawValue,
        "workId": workID
    ]
    var response: [String: Any] = [
        "commandId": command.commandId.uuidString.lowercased(),
        "commandKind": command.commandKind,
        "receipt": receipt,
        "result": result.rawValue
    ]
    switch command.commandKind {
    case "prepareObject":
        if result == .applied {
            response["expiresAt"] = "2030-01-01T00:00:00Z"
            response["objectId"] = payload["objectId"]
            response["uploadCapability"] = String(repeating: "c", count: 32)
            response["uploadId"] = UUID().uuidString.lowercased()
        }
    case "registerSnapshot":
        response["head"] = NSNull()
        response["snapshotId"] = payload["snapshotId"]
    case "finalizeObject":
        response["byteCount"] = payload["byteCount"]
        response["head"] = NSNull()
        response["objectId"] = payload["objectId"]
    case "createWork":
        response["documentId"] = payload["documentId"]
        response["head"] = NSNull()
        response["workId"] = payload["workId"]
    case "resolveServer":
        response["conflictId"] = payload["conflictId"]
        response["conflictRevision"] = payload["conflictRevision"]
        response["head"] = head.map(productionHead) ?? NSNull()
        response["remoteGeneration"] = head?.generation as Any
        response["remoteSnapshotId"] = payload["remoteSnapshotId"]
    case "resolveDevice":
        response["conflictId"] = payload["conflictId"]
        response["conflictRevision"] = payload["conflictRevision"]
        response["generation"] = head?.generation as Any
        response["head"] = head.map(productionHead) ?? NSNull()
        response["snapshotId"] = payload["decisionSnapshotId"]
    case "cloneWork":
        response["conflictId"] = payload["conflictId"]
        response["conflictRevision"] = payload["conflictRevision"]
        response["head"] = cloneHead.map(productionHead) ?? NSNull()
        response["newRootSnapshotId"] = payload["newRootSnapshotId"]
        response["newWorkId"] = payload["newWorkId"]
    case "publish" where result == .conflictPending:
        response["conflictId"] = UUID().uuidString.lowercased()
        response["conflictRevision"] = 1
        response["head"] = head.map(productionHead) ?? NSNull()
        response["sourceGeneration"] = command.sourceGeneration
    default:
        response["generation"] = head?.generation as Any
        response["head"] = head.map(productionHead) ?? NSNull()
        response["snapshotId"] = payload["candidateSnapshotId"] ?? payload["snapshotId"] ?? NSNull()
    }
    return try productionJSON(response)
}

private func productionHead(_ head: V2RemoteHead) -> [String: Any] {
    ["generation": head.generation, "snapshotId": head.snapshotID.rawValue]
}

private func productionJSON(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
