import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2Application
import Observation
import os
import Testing

@MainActor
struct IOSWorkspaceModelObservationTests {
    @Test("共有モデルの直接参照は変更をObservationで追跡する")
    func directModelReadsTrackSharedState() throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let state = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url,
                                     runtimeComposition: .test(configuration))
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
    }
}
