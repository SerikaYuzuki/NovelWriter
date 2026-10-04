#if FUMINIWA_TEST_COMPOSITION
import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspaceUI

extension IOSDocumentStore {
    var isLibraryPreview: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--library-preview=") }
    }

    /// Test-host only. Data is a shelf projection, never a real account or manuscript.
    func installLibraryPreviewIfRequested() -> Bool {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--library-preview=") }) else { return false }
        let mode = String(argument.dropFirst("--library-preview=".count))
        let preview = LibraryPreview(mode: mode)
        syncV2LibraryItems = preview.items
        if let importing = preview.importingWorkID {
            snapshotSyncV2RemoteOnlyOpeningWorkID = importing
            snapshotSyncV2RemoteOnlyOpenStartedAt = Date().addingTimeInterval(-16)
        }
        libraryImportFailures.merge(preview.importFailures) { _, new in new }
        libraryImportPhases.merge(preview.importPhases) { _, new in new }
        syncV2RemoteCatalogError = preview.failure
        libraryIsLoading = preview.isLoading
        startupState = .library
        return true
    }
}
#endif
