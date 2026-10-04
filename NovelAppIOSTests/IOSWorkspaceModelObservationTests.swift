import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2Application
import Observation
import os
import Testing

@MainActor
struct IOSWorkspaceModelObservationTests {
    @Test("共有モデルへの変更はadapterを読む画面のObservationを無効化する")
    func forwardersTrackSharedState() throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let state = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url,
                                     runtimeComposition: .test(configuration))
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
        #expect(state.assistantRequestCenter === state.workspaceModel.assistantRequestCenter)
    }
}
