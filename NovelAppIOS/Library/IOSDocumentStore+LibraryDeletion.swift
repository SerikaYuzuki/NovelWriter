import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

extension IOSDocumentStore {
    func libraryDeletionDisabledReason(for workID: WorkID) -> String? {
        if libraryPrefetchWorkID == workID || snapshotSyncV2RemoteOnlyOpeningWorkID == workID {
            return "作品を取り込み中のため削除できません。取り込みを中止するか、完了後に再試行してください。"
        }
        if isDocumentTransitionInProgress || isSyncV2RemoteAccountTransitionActive {
            return "作品やアカウントを切り替え中です。完了後に再試行してください。"
        }
        return nil
    }

    func deleteLibraryWork(
        _ item: SyncV2LibraryItem, expectedSession: IOSDocumentSessionToken?,
        accountScope: IOSSnapshotSyncV2AccountScope
    ) async -> Bool {
        guard let application = snapshotSyncV2Application,
              currentDocumentSessionToken == expectedSession,
              matchesSyncAccount(accountScope),
              libraryDeletionDisabledReason(for: item.workID) == nil else { return false }
        let context = SyncOperationContext(workID: syncV2ActiveWorkID, session: expectedSession,
                                           account: accountScope, editGeneration: nil)
        cancelSnapshotSyncV2BackgroundOperations()
        let prepared = await documentOperationGate.perform { [weak self] in
            guard let self, matchesSyncOperation(context),
                  libraryDeletionDisabledReason(for: item.workID) == nil else { return false }
            return await performDocumentTransition {
                // IME may legitimately advance the edit generation during the
                // transition. Freeze it only after input and local save finish.
                let generation = localEditGeneration
                try await saveCoordinator.performExclusive {
                    try await syncSessionController.prepareWorkDeletion(
                        application: application, workID: item.workID,
                        isCurrent: {
                            matchesSyncOperation(context) && localEditGeneration == generation
                                && !isSyncV2AccountTransitionActive
                        }
                    ) {
                        if syncV2ActiveWorkID == item.workID {
                            retireDeletedWork()
                        }
                    }
                }
            }
        }
        guard prepared else { return false }
        // The intent is durable. A slow/offline server must not own the gate.
        _ = await refreshLibrary()
        guard matchesSyncAccount(accountScope), !isSyncV2RemoteAccountTransitionActive else { return false }
        do {
            try await application.deleteWork(workID: item.workID)
            guard matchesSyncAccount(accountScope) else { return false }
            syncV2RemoteCatalogItems.removeAll { $0.workID == item.workID }
            _ = await refreshLibrary()
            return true
        } catch {
            guard matchesSyncAccount(accountScope) else { return false }
            operationErrorMessage = "削除はまだ完了していません。端末のデータを保持して削除待ちにしました。接続時に再試行します。「作品を削除…」からも再試行できます。"
            _ = await refreshLibrary()
            return false
        }
    }

    private func retireDeletedWork() {
        startupState = .library
        syncV2ActiveWorkID = nil
        syncV2KeepBothPendingWorkID = nil
        document = NovelDocument.newDocument()
        documentURL = libraryRoot
        replaceAttachments([])
        syncV2AttachmentPayloads = [:]
        syncV2AttachmentIDs = [:]
        syncV2PortableResources = []
        syncV2PortableCreatedAt = nil
        selectedChapterID = nil
        selectedEpisodeID = nil
        syncV2HistoryItems = []
        syncV2HistoryWorkID = nil
        syncV2HistoryCursor = nil
        syncV2HistoryLocalAvailability = .unavailable
        syncV2HistoryOnlineAvailability = .unavailable
        syncV2HistoryOnlineFailure = nil
        snapshotSyncConflict = nil
        snapshotSyncState = nil
        snapshotSyncOutcome = nil
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        saveState = .saved
        userDefaults.removeObject(forKey: Self.lastWorkIDKey)
    }
}
