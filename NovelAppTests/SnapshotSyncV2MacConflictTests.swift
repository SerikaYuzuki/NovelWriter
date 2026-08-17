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
    @Test("all three conflict choices remain explicit")
    func conflictActionsPreserveThreeChoices() throws {
        let workID = WorkID(UUID())
        let conflictID = UUID()
        let local = try SnapshotID(rawValue: String(repeating: "a", count: 64))
        let remote = try SnapshotID(rawValue: String(repeating: "b", count: 64))
        let choices: [SyncV2ConflictChoice] = [.useDevice, .useServer, .keepBoth]
        let actions = choices.map {
            SyncV2ConflictAction(
                workID: workID,
                conflictID: conflictID,
                revision: 1,
                baseSnapshotID: nil,
                localSnapshotID: local,
                remoteSnapshotID: remote,
                sourceGeneration: 1,
                choice: $0
            )
        }
        #expect(actions.map(\.choice) == choices)
    }

    @Test("keep-both returned work is installed before the worker wake")
    @MainActor
    func keepBothOpenedWorkHandsOffTheEditorBeforeResume() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .suspended)
        let beforeOperations = await fixture.remote.recordedOperations().count

        #expect(await fixture.state.resolveSnapshotConflict(using: .keepBoth))
        let activeWorkID = try #require(fixture.state.snapshotSyncV2ActiveWorkID)
        #expect(activeWorkID != fixture.workID)
        #expect(activeWorkID == fixture.state.documentSessionToken.workID)
        #expect(fixture.state.document.id != fixture.document.id)

        // The helper wakes the shared worker only after the opened clone has
        // been installed. The suspended fake makes the ordering observable.
        try await eventuallyMac {
            await fixture.remote.recordedOperations().count > beforeOperations
        }
        #expect(fixture.state.snapshotSyncV2ActiveWorkID == activeWorkID)
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
        #expect(fixture.state.saveState == .saved)
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
        #expect(fixture.state.saveState == .unsaved)
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
        #expect(fixture.state.saveState == .saved)
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
        #expect(fixture.state.snapshotSyncV2ActiveWorkID == replacementWorkID)
        #expect(fixture.state.document.title == "切替後の作品")
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
        #expect(fixture.state.saveState == .saved)
    }
}
