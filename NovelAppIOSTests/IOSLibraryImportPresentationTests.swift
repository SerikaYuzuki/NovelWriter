import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelWorkspace
import Testing

@MainActor
@Suite("Library import navigation", .serialized)
struct IOSLibraryImportPresentationTests {
    @Test("A completed import respects subsequent navigation and keeps the current document", arguments: [false, true])
    func completionRespectsNavigation(navigatedAway: Bool) async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url,
                                     runtimeComposition: .test(configuration))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let original = try #require(store.syncV2ActiveWorkID)
        let application = try #require(store.snapshotSyncV2Application)
        let target = WorkID(UUID())
        let document = NovelDocument.newDocument(title: "サンプル作品")
        // Emulate the durable install boundary: the shelf still has a remote row,
        // while application.open can already return the verified local import.
        _ = try await application.checkpoint(workID: target, document: document, reason: .migration, documentCreatedAt: Date())
        store.syncV2LibraryItems = [.init(workID: target, title: document.title,
                                          availability: .remoteOnly, accountState: .active)]
        var navigatedSession: WorkspaceSessionToken?
        #expect(await store.startRemoteOnlySnapshotSyncV2Open(workID: target,
                                                              shouldOpen: { !navigatedAway }, onOpened: { navigatedSession = $0 }))
        let task = try #require(store.snapshotSyncV2RemoteOnlyOpenTask)
        await task.value
        if navigatedAway {
            #expect(store.syncV2ActiveWorkID == original)
            #expect(navigatedSession == nil)
            #expect(store.libraryNotice == "『サンプル作品』をこの端末に取り込みました")
        } else {
            #expect(store.syncV2ActiveWorkID == target)
            #expect(navigatedSession?.workID == target)
        }
        #expect(store.snapshotSyncV2RemoteOnlyOpeningWorkID == nil)
        #expect(store.syncV2LibraryItems.contains { $0.workID == target && $0.availability != .remoteOnly })
    }

    @Test("Leaving and returning to the same route still invalidates an import navigation request")
    func routeGeneration() {
        let navigation = IOSWorkspaceNavigationCoordinator()
        let generation = navigation.navigationGeneration
        let session = WorkspaceSessionToken(generation: 1, documentID: UUID(), workID: WorkID(UUID()))
        navigation.showProjectHome(for: session)
        navigation.updatePath([]) { _ in true }
        #expect(navigation.path.isEmpty)
        #expect(navigation.navigationGeneration != generation)
    }
}

extension IOSLibraryImportPresentationTests {
    @Test("Manual take refreshes the shelf without navigating or replacing the current editor")
    func manualTakeDoesNotOpen() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url,
                                     runtimeComposition: .test(configuration))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let original = store.currentDocumentSessionToken
        let originalDocument = store.document.id
        let application = try #require(store.snapshotSyncV2Application)
        let target = WorkID(UUID())
        _ = try await application.checkpoint(workID: target, document: .newDocument(title: "取得した作品"),
                                             reason: .migration, documentCreatedAt: Date())
        store.syncV2LibraryItems = [.init(workID: target, title: "取得した作品", availability: .remoteOnly, accountState: .active)]
        store.takeOntoDevice(workID: target, title: "取得した作品")
        let task = try #require(store.libraryPrefetchTask)
        await task.value
        #expect(store.currentDocumentSessionToken == original)
        #expect(store.document.id == originalDocument)
        #expect(store.libraryPrefetchTask == nil)
        #expect(store.syncV2LibraryItems.contains { $0.workID == target && $0.availability != .remoteOnly })
    }
}

extension IOSLibraryImportPresentationTests {
    @Test("Local open failure is visible without losing the current document or blocking another open")
    func localOpenFailureKeepsShelfUsable() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url,
                                     runtimeComposition: .test(configuration))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let original = store.document
        let workID = try #require(store.syncV2ActiveWorkID)
        #expect(await !store.openSnapshotSyncV2(workID: UUID()))
        #expect(store.operationErrorMessage?.isEmpty == false)
        #expect(store.snapshotSyncV2RemoteOnlyOpenFailure != nil)
        #expect(store.document == original)
        #expect(store.syncV2ActiveWorkID == workID)
        #expect(await store.openSnapshotSyncV2(workID: workID.rawValue))
        #expect(store.snapshotSyncV2RemoteOnlyOpenFailure == nil)
    }
}
