#if FUMINIWA_TEST_COMPOSITION
import Foundation
import NovelSyncV2
import NovelSyncV2Application

extension AppState {
    /// Test-host only. No runtime, network, credentials, or document is opened.
    func installLibraryPreviewIfRequested() -> Bool {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--library-preview=") }) else { return false }
        let mode = String(argument.dropFirst("--library-preview=".count))
        let remote = WorkID(UUID())
        let importing = WorkID(UUID())
        let failed = WorkID(UUID())
        let local = WorkID(UUID())
        snapshotSyncLibraryWorks = (mode == "states" || mode.hasPrefix("import-")) ? [
            .init(id: remote.rawValue, title: "01 海辺の便り", availability: .remoteOnly,
                  workID: remote, remoteProgress: .idle, accountState: .active),
            .init(id: importing.rawValue, title: "02 季節の記録", availability: .remoteOnly,
                  workID: importing, remoteProgress: .idle, accountState: .active),
            .init(id: failed.rawValue, title: "03 雨あがりの書斎", availability: mode.hasPrefix("import-") ? .remoteOnly : .cached,
                  workID: failed, remoteProgress: .failed(.remoteWorkDeleted), accountState: .active),
            .init(id: local.rawValue, title: "04 はじまりの庭", availability: .local,
                  workID: local, remoteProgress: .idle)
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
        snapshotSyncLibraryFailure = mode == "offline" ? .offline : nil
        snapshotSyncLibraryIsLoading = mode == "loading"
        lastStartupLibraryConnection = mode == "offline" ? .offline : .accountRequired
        startupState = .documentSelection(.init(works: snapshotSyncLibraryWorks,
                                                presentation: .localAndRemote, connection: mode == "offline" ? .offline : .accountRequired))
        return true
    }
}
#endif
