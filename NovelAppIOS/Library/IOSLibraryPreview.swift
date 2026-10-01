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
        let failed = WorkID(UUID())
        syncV2LibraryItems = (mode == "states" || mode.hasPrefix("import-")) ? [
            .init(workID: WorkID(UUID()), title: "01 海辺の便り", availability: .remoteOnly, accountState: .active),
            .init(workID: importing, title: "02 季節の記録", availability: .remoteOnly, accountState: .active),
            .init(workID: failed, title: "03 雨あがりの書斎", availability: mode.hasPrefix("import-") ? .remoteOnly : .cached,
                  accountState: .active, remoteProgress: .failed(.remoteWorkDeleted)),
            .init(workID: WorkID(UUID()), title: "04 はじまりの庭", availability: .localOnly, accountState: .unbound)
        ] : []
        if mode == "states" || mode == "import-totals" || mode == "import-unknown" || mode == "import-cancel" {
            snapshotSyncV2RemoteOnlyOpeningWorkID = importing
            snapshotSyncV2RemoteOnlyOpenStartedAt = Date().addingTimeInterval(-16)
        }
        if mode.hasPrefix("import-") {
            libraryImportFailures[failed] = .retryable(.lostResponse)
            if mode != "import-menu" {
                libraryImportPhases[importing] = ImportPhase(receivedBytes: 8_200_000,
                                                             totalBytes: mode != "import-unknown" ? 19_000_000 : nil)
            }
        }
        syncV2RemoteCatalogError = mode == "offline" ? .offline : nil
        libraryIsLoading = mode == "loading"
        startupState = .library
        return true
    }
}
#endif
