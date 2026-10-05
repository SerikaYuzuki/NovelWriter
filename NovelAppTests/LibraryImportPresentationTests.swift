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

extension LibraryImportPresentationTests {
    @Test("Manual take refreshes the shelf without replacing the current editor")
    func manualTakeDoesNotOpen() async throws {
        let configuration = try TestRuntimeConfiguration()
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults, snapshotSyncV2Factory: {
            try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        }))
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let originalWork = state.currentSnapshotSyncV2WorkID
        let originalDocument = state.workspaceModel.document.id
        let application = try #require(state.snapshotSyncV2Application)
        let target = WorkID(UUID())
        _ = try await application.checkpoint(workID: target, document: .newDocument(title: "取得した作品"),
                                             reason: .migration, documentCreatedAt: Date())
        state.snapshotSyncLibraryWorks = [.init(id: target.rawValue, title: "取得した作品", availability: .remoteOnly,
                                                workID: target, remoteProgress: .idle, accountState: .active)]
        state.takeOntoDevice(workID: target, title: "取得した作品")
        let task = try #require(state.libraryPrefetchTask)
        await task.value
        #expect(state.currentSnapshotSyncV2WorkID == originalWork)
        #expect(state.workspaceModel.document.id == originalDocument)
        #expect(state.libraryPrefetchTask == nil)
        #expect(state.snapshotSyncLibraryWorks.contains { $0.workID == target && $0.availability != .remoteOnly })
    }
}

extension LibraryImportPresentationTests {
    @Test("A failed safe-adoption shelf open is visible and another work remains openable")
    func localOpenFailureKeepsShelfUsable() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        var dependencies = AppDependencies(userDefaults: defaults, snapshotSyncV2Factory: {
            try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        })
        let failedID = WorkID(UUID())
        dependencies.snapshotSyncV2OpenLocalOverride = { application, workID in
            if workID == failedID {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            return try await application.openLocal(workID: workID)
        }
        let state = AppState(dependencies: dependencies)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let application = try #require(state.snapshotSyncV2Application)
        let goodID = WorkID(UUID())
        _ = try await application.checkpoint(workID: goodID, document: .newDocument(title: "開ける作品"),
                                             reason: .migration, documentCreatedAt: Date())
        #expect(await state.returnToSnapshotLibrary())
        let original = state.workspaceModel.document
        let failed = StartupLibraryWork(id: failedID.rawValue, title: "失敗する作品", availability: .cached,
                                        workID: failedID, remoteProgress: .readyForSafeAdoption(inboxID: UUID()), accountState: .active)
        #expect(await !state.openLibraryWork(failed))
        #expect(state.snapshotSyncLibraryOpenFailure != nil)
        #expect(state.operationMessage?.isEmpty == false)
        #expect(!state.startupState.isReady)
        #expect(state.workspaceModel.document == original)
        let good = StartupLibraryWork(id: goodID.rawValue, title: "開ける作品", availability: .local, workID: goodID,
                                      remoteProgress: .idle, accountState: .unbound)
        #expect(await state.openLibraryWork(good))
        #expect(state.currentSnapshotSyncV2WorkID == goodID)
        #expect(state.snapshotSyncLibraryOpenFailure == nil)
    }
}
