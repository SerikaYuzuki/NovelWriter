#if FUMINIWA_TEST_COMPOSITION
import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspaceUI

extension AppState {
    /// Test-host only. No runtime, network, credentials, or document is opened.
    func installLibraryPreviewIfRequested() -> Bool {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--library-preview=") }) else { return false }
        let mode = String(argument.dropFirst("--library-preview=".count))
        let preview = LibraryPreview(mode: mode)
        snapshotSyncLibraryWorks = preview.items.compactMap(Self.startupLibraryWork).map { $0.1 }
        if let importing = preview.importingWorkID {
            snapshotSyncV2RemoteOnlyOpeningWorkID = importing
            snapshotSyncV2RemoteOnlyOpenStartedAt = Date().addingTimeInterval(-16)
        }
        libraryImportFailures.merge(preview.importFailures) { _, new in new }
        libraryImportPhases.merge(preview.importPhases) { _, new in new }
        snapshotSyncLibraryFailure = preview.failure
        snapshotSyncLibraryIsLoading = preview.isLoading
        lastStartupLibraryConnection = mode == "offline" ? .offline : .accountRequired
        startupState = .documentSelection(.init(works: snapshotSyncLibraryWorks,
                                                presentation: .localAndRemote, connection: mode == "offline" ? .offline : .accountRequired))
        return true
    }
}
#endif
