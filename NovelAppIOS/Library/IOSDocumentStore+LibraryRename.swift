import Foundation
import NovelSyncV2
import NovelSyncV2Application

extension IOSDocumentStore {
    func renameLibraryWork(
        _ item: SyncV2LibraryItem, title: String,
        expectedSession: IOSDocumentSessionToken?,
        accountScope: IOSSnapshotSyncV2AccountScope
    ) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let application = snapshotSyncV2Application,
              currentDocumentSessionToken == expectedSession,
              matchesSyncAccount(accountScope),
              !isSyncV2AccountTransitionActive else { return false }
        do {
            // Only a server-only work needs a download; local renames stay offline.
            if item.availability == .remoteOnly {
                // The application joins any open already importing this WorkID.
                _ = try await openRemoteOnlyWithBackgroundTime(application, workID: item.workID)
            }
            let renamed = await documentOperationGate.perform { [weak self] in
                guard let self, currentDocumentSessionToken == expectedSession,
                      matchesSyncAccount(accountScope),
                      !isSyncV2AccountTransitionActive else { return false }
                return await performDocumentTransition {
                    try await saveCoordinator.performExclusive {
                        guard currentDocumentSessionToken == expectedSession,
                              matchesSyncAccount(accountScope),
                              !isSyncV2AccountTransitionActive else {
                            throw SyncV2ApplicationError.safeBoundaryRejected
                        }
                        _ = try await application.renameLocalWork(workID: item.workID, title: title)
                        guard currentDocumentSessionToken == expectedSession,
                              matchesSyncAccount(accountScope) else {
                            throw SyncV2ApplicationError.safeBoundaryRejected
                        }
                        if syncV2ActiveWorkID == item.workID {
                            document.title = title
                        }
                    }
                }
            }
            guard renamed else { return false }
            _ = await refreshLibrary()
            return true
        } catch {
            operationErrorMessage = "作品名を変更できませんでした。接続を確認して再試行してください。"
            return false
        }
    }
}
