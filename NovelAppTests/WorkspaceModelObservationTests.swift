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
    @Test("共有モデルの直接参照は変更をObservationで追跡する")
    func directModelReadsTrackSharedState() {
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()))
        let documentChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.workspaceModel.document.title
        } onChange: {
            documentChanged.withLock { $0 = true }
        }
        state.workspaceModel.document.title = "変更した作品"
        #expect(documentChanged.withLock { $0 })
        #expect(state.workspaceModel.document.title == "変更した作品")

        let selectionChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.workspaceModel.selectedEpisodeID
        } onChange: {
            selectionChanged.withLock { $0 = true }
        }
        state.workspaceModel.selectedEpisodeID = nil
        #expect(selectionChanged.withLock { $0 })
        #expect(state.workspaceModel.selectedEpisodeID == nil)

        let saveChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.workspaceModel.saveState
        } onChange: {
            saveChanged.withLock { $0 = true }
        }
        state.workspaceModel.saveState = .saving
        #expect(saveChanged.withLock { $0 })
        #expect(state.workspaceModel.saveState == .saving)
        state.workspaceModel.saveState = .saved
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
    }
}
