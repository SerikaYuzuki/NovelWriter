#if FUMINIWA_TEST_COMPOSITION
import Foundation
import NovelSyncV2
import NovelSyncV2Application

extension IOSDocumentStore {
    var isLibraryPreview: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--library-preview=") }
    }

    /// Test-host only. Data is a shelf projection, never a real account or manuscript.
    func installLibraryPreviewIfRequested() -> Bool {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--library-preview=") }) else { return false }
        let mode = String(argument.dropFirst("--library-preview=".count))
        let importing = WorkID(UUID())
        syncV2LibraryItems = mode == "states" ? [
            .init(workID: WorkID(UUID()), title: "01 海辺の便り", availability: .remoteOnly, accountState: .active),
            .init(workID: importing, title: "02 季節の記録", availability: .remoteOnly, accountState: .active),
            .init(workID: WorkID(UUID()), title: "03 雨あがりの書斎", availability: .cached,
                  accountState: .active, remoteProgress: .failed(.remoteWorkDeleted)),
            .init(workID: WorkID(UUID()), title: "04 はじまりの庭", availability: .localOnly, accountState: .unbound)
        ] : []
        if mode == "states" {
            snapshotSyncV2RemoteOnlyOpeningWorkID = importing
            snapshotSyncV2RemoteOnlyOpenStartedAt = Date().addingTimeInterval(-16)
        }
        syncV2RemoteCatalogError = mode == "offline" ? .offline : nil
        libraryIsLoading = mode == "loading"
        startupState = .library
        return true
    }
}
#endif
