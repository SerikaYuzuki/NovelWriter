import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import SwiftUI

extension AppState: WorkspaceLibraryImportHost {
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
        LibraryCoordinator(operations: LibraryOperations(application: application)).takeOntoDevice(
            workID: workID, title: title, controller: syncSessionController, host: self
        )
    }
}
