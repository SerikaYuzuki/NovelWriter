import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Runtime
import Observation
import os
import Testing

@MainActor
struct WorkspaceModelObservationTests {
    @Test("共有モデルへの変更はadapterを読む画面のObservationを無効化する")
    func forwardersTrackSharedState() {
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()))
        let documentChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.document.title
        } onChange: {
            documentChanged.withLock { $0 = true }
        }
        state.workspaceModel.document.title = "変更した作品"
        #expect(documentChanged.withLock { $0 })
        #expect(state.document.title == "変更した作品")

        let selectionChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.selectedEpisodeID
        } onChange: {
            selectionChanged.withLock { $0 = true }
        }
        state.workspaceModel.selectedEpisodeID = nil
        #expect(selectionChanged.withLock { $0 })
        #expect(state.selectedEpisodeID == nil)

        let saveChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.saveState
        } onChange: {
            saveChanged.withLock { $0 = true }
        }
        state.workspaceModel.saveState = .saving
        #expect(saveChanged.withLock { $0 })
        #expect(state.saveState == .saving)
        state.saveState = .saved
        #expect(state.workspaceModel.saveState == .saved)
        let workID = WorkID(UUID())
        let displayID = UUID()
        let row = StartupLibraryWork(id: displayID, title: "棚の作品", availability: .pending,
                                     workID: workID, remoteProgress: .idle)
        state.snapshotSyncLibraryWorks = [row]
        #expect(state.snapshotSyncLibraryWorks == [row])
        let shelfChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.snapshotSyncLibraryWorks.first?.title
        } onChange: {
            shelfChanged.withLock { $0 = true }
        }
        state.workspaceModel.libraryRows = []
        #expect(shelfChanged.withLock { $0 })
        #expect(state.snapshotSyncLibraryWorks.isEmpty)
        #expect(state.assistantRequestCenter === state.workspaceModel.assistantRequestCenter)
    }
}
