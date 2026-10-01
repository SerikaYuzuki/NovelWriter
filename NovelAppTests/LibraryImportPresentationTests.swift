import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct LibraryImportPresentationTests {
    @Test("Remote open returns success only with the imported work installed")
    func successMeansInstalled() async throws {
        let configuration = try TestRuntimeConfiguration()
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults, snapshotSyncV2Factory: {
            try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        }))
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let application = try #require(state.snapshotSyncV2Application)
        let target = WorkID(UUID())
        _ = try await application.checkpoint(workID: target, document: .newDocument(title: "サンプル作品"),
                                             reason: .migration, documentCreatedAt: Date())
        #expect(await state.returnToSnapshotLibrary())
        await state.refreshSnapshotLibrary()
        let row = StartupLibraryWork(id: target.rawValue, title: "サンプル作品", availability: .remoteOnly,
                                     workID: target, remoteProgress: .idle, accountState: .active)
        state.snapshotSyncLibraryWorks = [row]
        #expect(await state.openLibraryWork(row))
        #expect(state.currentSnapshotSyncV2WorkID == target)
        #expect(state.startupState.isReady)
        #expect(state.snapshotSyncV2RemoteOnlyOpeningWorkID == nil)
        #expect(state.snapshotSyncV2RemoteOnlyOpenTask == nil)
    }
}
