import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@Suite("macOS Snapshot Sync v2 conflict choices")
struct SnapshotSyncV2MacConflictTests {
    @Test("keep-both returned work is installed before the worker wake")
    @MainActor
    func keepBothOpenedWorkHandsOffTheEditorBeforeResume() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .suspended)
        let beforeOperations = await fixture.remote.recordedOperations().count

        #expect(await fixture.state.resolveSnapshotConflict(using: .keepBoth))
        let activeWorkID = try #require(fixture.state.workspaceModel.activeWorkID)
        #expect(activeWorkID != fixture.workID)
        #expect(activeWorkID == fixture.state.workspaceModel.documentSessionToken.workID)
        #expect(fixture.state.workspaceModel.document.id != fixture.document.id)

        // The helper wakes the shared worker only after the opened clone has
        // been installed. The suspended fake makes the ordering observable.
        try await eventuallyMac {
            await fixture.remote.recordedOperations().count > beforeOperations
        }
        #expect(fixture.state.workspaceModel.activeWorkID == activeWorkID)
        await fixture.remote.resumeSuspended()
        await fixture.remote.setBehaviors([.failure(.offline)])
        let restarted = try await SnapshotSyncV2Runtime.makeApplication(
            mode: .test(fixture.configuration)
        )
        let reopenedClone = try await restarted.open(workID: activeWorkID)
        #expect(reopenedClone.document?.title == fixture.document.title)
        #expect(reopenedClone.document?.chapters.first?.episodes.first?.content == "本文")
        let reopenedSourceState = await restarted.uiState(workID: fixture.workID)
        #expect(reopenedSourceState?.conflict == nil)
    }

    @Test("useServer選択は競合の本文を暗黙checkpointしない")
    @MainActor
    func conflictChoiceDoesNotCheckpointEditor() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .failure(.offline))
        let openedBefore = try await fixture.application.open(workID: fixture.workID)
        let operationsBefore = await fixture.remote.recordedOperations().count

        #expect(await fixture.state.resolveSnapshotConflict(using: .useServer))
        let openedAfter = try await fixture.application.open(workID: fixture.workID)
        #expect(openedAfter.generation == openedBefore.generation)
        #expect(openedAfter.document?.title == fixture.document.title)
        #expect(fixture.state.workspaceModel.saveState == .saved)
        #expect(await fixture.remote.recordedOperations().count >= operationsBefore)
    }

    @Test("dirty競合は本文と世代を保持して選択を保留する")
    @MainActor
    func dirtyConflictChoiceLeavesConflictPending() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .failure(.offline))
        let openedBefore = try await fixture.application.open(workID: fixture.workID)
        let operationsBefore = await fixture.remote.recordedOperations().count
        fixture.state.markDocumentDirty()

        #expect(await fixture.state.resolveSnapshotConflict(using: .useServer) == false)
        let openedAfter = try await fixture.application.open(workID: fixture.workID)
        #expect(openedAfter.generation == openedBefore.generation)
        #expect(openedAfter.document?.title == fixture.document.title)
        #expect(fixture.state.workspaceModel.saveState == .unsaved)
        #expect(fixture.state.operationMessage != nil)
        #expect(await fixture.remote.recordedOperations().count == operationsBefore)
        #expect(await fixture.application.uiState(workID: fixture.workID)?.conflict != nil)
    }

    @Test("競合選択はmodelと異なるeditor本文を保留する")
    @MainActor
    func conflictChoiceRejectsEditorCaptureDifferentFromModel() async throws {
        let fixture = try await makeMacConflictFixture(
            remoteBehavior: .failure(.offline),
            committedText: "modelと異なる入力"
        )
        let openedBefore = try await fixture.application.open(workID: fixture.workID)
        let operationsBefore = await fixture.remote.recordedOperations().count

        #expect(await fixture.state.resolveSnapshotConflict(using: .useServer) == false)
        let openedAfter = try await fixture.application.open(workID: fixture.workID)
        #expect(openedAfter.generation == openedBefore.generation)
        #expect(openedAfter.document?.title == fixture.document.title)
        #expect(fixture.state.workspaceModel.saveState == .saved)
        #expect(fixture.state.operationMessage != nil)
        #expect(await fixture.remote.recordedOperations().count == operationsBefore)
        #expect(await fixture.application.uiState(workID: fixture.workID)?.conflict != nil)
    }

    @Test("競合シートの古いWorkIDとCAS値は作品切替後に適用しない")
    @MainActor
    func staleConflictSelectionCannotCrossDocumentSession() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .failure(.offline))
        await fixture.state.refreshSnapshotSyncV2UIState()
        let selection = try #require(fixture.state.snapshotSyncV2ConflictSelection)
        let replacementWorkID = WorkID(UUID())
        fixture.state.installV2Document(
            NovelDocument.newDocument(title: "切替後の作品"),
            workID: replacementWorkID,
            createdAt: Date()
        )

        #expect(
            await fixture.state.resolveSnapshotConflict(
                using: .useServer,
                selection: selection
            ) == false
        )
        #expect(fixture.state.workspaceModel.activeWorkID == replacementWorkID)
        #expect(fixture.state.workspaceModel.document.title == "切替後の作品")
    }

    @Test("editorなしの別セクションではuseServer選択を保留しない")
    @MainActor
    func conflictChoiceAllowsInactiveEditorOutsideStructure() async throws {
        let fixture = try await makeMacConflictFixture(
            remoteBehavior: .failure(.offline),
            committedCapture: .notActive
        )
        fixture.state.workspaceSelection = WorkspaceSelection(section: .characters)
        let openedBefore = try await fixture.application.open(workID: fixture.workID)

        #expect(await fixture.state.resolveSnapshotConflict(using: .useServer))
        let openedAfter = try await fixture.application.open(workID: fixture.workID)
        #expect(openedAfter.generation == openedBefore.generation)
        #expect(openedAfter.document?.title == fixture.document.title)
        #expect(fixture.state.workspaceModel.saveState == .saved)
    }

    @Test("keep-bothはclone installが完了するまで元作品への編集・checkpointを止める")
    @MainActor
    func keepBothFreezesSourceUntilHandoff() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .suspended)
        let before = try await fixture.application.openLocal(workID: fixture.workID)
        var observed = false
        fixture.state.snapshotSyncV2BeforeKeepBothInstallOverride = {
            observed = true
            #expect(fixture.state.workspaceModel.keepBothPendingWorkID != nil)
            #expect(!fixture.state.permitsDocumentInteraction)
            #expect(fixture.state.currentSnapshotSyncV2WorkID == fixture.workID)
            #expect(await fixture.state.checkpointSnapshotSyncV2(fixture.state.workspaceModel.document) == false)
            let reopened = try? await fixture.application.openLocal(workID: fixture.workID)
            #expect(reopened?.generation == before.generation)
        }
        #expect(await fixture.state.resolveSnapshotConflict(using: .keepBoth))
        #expect(observed)
        #expect(fixture.state.currentSnapshotSyncV2WorkID != fixture.workID)
        #expect(fixture.state.workspaceModel.keepBothPendingWorkID == nil)
        #expect(fixture.state.permitsDocumentInteraction)
        fixture.state.snapshotSyncV2BeforeKeepBothInstallOverride = nil
        await fixture.remote.resumeSuspended()
    }

    @Test("表示後にprojectionまたは編集世代が変わった競合選択は拒否する", arguments: ["projection", "generation"])
    @MainActor
    func changedDisplayedSelectionIsRejected(change: String) async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .failure(.offline))
        let selection = try #require(fixture.state.snapshotSyncV2ConflictSelection)
        let before = try await fixture.application.openLocal(workID: fixture.workID)
        if change == "generation" {
            // Even if a later save has returned to .saved, the old sheet is stale.
            fixture.state.markDocumentDirty()
            #expect(await fixture.state.saveNow())
        } else {
            let conflict = selection.conflict
            let newer = SyncV2ConflictProjection(
                conflictID: conflict.conflictID, revision: conflict.revision + 1,
                baseSnapshotID: conflict.baseSnapshotID, localSnapshotID: conflict.localSnapshotID,
                remoteSnapshotID: conflict.remoteSnapshotID, sourceGeneration: conflict.sourceGeneration
            )
            fixture.state.workspaceModel.syncConflict = newer
            fixture.state.workspaceModel.syncUIState = SyncUIState(
                workID: fixture.workID, localDurability: before.snapshotID.map { .saved(generation: before.generation, snapshotID: $0) } ?? .unsaved,
                remoteProgress: .needsChoice, conflict: newer, lastTypedResult: .conflictPending
            )
        }
        #expect(await fixture.state.resolveSnapshotConflict(using: .useServer, selection: selection) == false)
        #expect(fixture.state.workspaceModel.document == fixture.document)
        #expect(try await fixture.application.openLocal(workID: fixture.workID).generation == before.generation)
        #expect(await fixture.application.uiState(workID: fixture.workID)?.conflict == selection.conflict)
    }

    @Test("failed keep-both can leave without checkpointing the source, open another work, or retry the same clone",
          arguments: ["library", "other", "retry"])
    @MainActor
    func failedHandoffRecovery(action: String) async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .failure(.offline))
        fixture.state.snapshotSyncV2KeepBothInstallOverride = { false }
        #expect(await fixture.state.resolveSnapshotConflict(using: .keepBoth) == false)
        let duplicateID = try #require(fixture.state.workspaceModel.keepBothPendingWorkID)
        #expect(!fixture.state.permitsDocumentInteraction)
        #expect(fixture.state.permitsDocumentDeparture)
        let original = fixture.state.workspaceModel.document
        let sourceBeforeDeparture = try await fixture.application.openLocal(workID: fixture.workID)
        let historyBefore = try await fixture.application.historyPage(workID: fixture.workID).items
        if action == "retry" {
            fixture.state.snapshotSyncV2KeepBothInstallOverride = { true }
            #expect(await fixture.state.retryKeepBothHandoff())
            #expect(fixture.state.currentSnapshotSyncV2WorkID == duplicateID)
            #expect(fixture.state.permitsDocumentInteraction)
        } else if action == "other" {
            let anotherID = WorkID(UUID())
            _ = try await fixture.application.checkpoint(workID: anotherID, document: .newDocument(title: "別作品"),
                                                         reason: .explicit, documentCreatedAt: Date())
            await fixture.state.refreshSnapshotLibrary()
            let another = try #require(fixture.state.snapshotSyncLibraryWorks.first { $0.workID == anotherID })
            fixture.state.workspaceModel.saveState = .failed
            #expect(await fixture.state.openLibraryWork(another))
            #expect(fixture.state.currentSnapshotSyncV2WorkID == anotherID)
        } else {
            fixture.state.workspaceModel.saveState = .failed
            #expect(await fixture.state.returnToSnapshotLibrary())
            guard case .documentSelection = fixture.state.startupState else { Issue.record("did not return to library"); return }
            #expect(fixture.state.currentSnapshotSyncV2WorkID == nil)
            #expect(!fixture.state.permitsDocumentInteraction)
        }
        #expect(fixture.state.workspaceModel.keepBothPendingWorkID == nil)
        #expect(fixture.state.workspaceModel.keepBothHandoff == nil)
        #expect(fixture.state.syncV2KeepBothSourceSelection == nil)
        let after = try await fixture.application.openLocal(workID: fixture.workID)
        #expect(after.generation == sourceBeforeDeparture.generation && after.document == original)
        #expect(try await fixture.application.historyPage(workID: fixture.workID).items == historyBefore)
    }
}
