import NovelSyncV2
import NovelWorkspace
import SwiftUI

extension IOSDocumentStore: WorkspaceLibraryImportHost {
    var libraryOpeningWorkID: WorkID? {
        snapshotSyncV2RemoteOnlyOpeningWorkID
    }

    func announceLibraryImport(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    func observeLibraryImports() async {
        await LibraryCoordinator.observeImports(host: self) {
            snapshotSyncV2Application.map { LibraryOperations(application: $0) }
        }
    }

    func cancelLibraryImport() async {
        await LibraryCoordinator.cancelImports(
            operations: snapshotSyncV2Application.map { LibraryOperations(application: $0) },
            controller: syncSessionController, host: self
        )
    }

    func takeOntoDevice(workID: WorkID, title: String) {
        guard let application = snapshotSyncV2Application else { return }
        var operations = LibraryOperations(application: application)
        operations.prefetch = { [self] in try await prefetchWithBackgroundTime(application, workID: $0) }
        LibraryCoordinator(operations: operations).takeOntoDevice(
            workID: workID, title: title, controller: syncSessionController, host: self
        )
    }
}
