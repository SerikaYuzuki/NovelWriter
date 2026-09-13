import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

extension AppState {
    /// The document gate covers the local intent and editor retirement only.
    /// Network deletion runs after it releases so other works remain usable.
    func deleteLibraryWork(_ work: StartupLibraryWork, accountScope: SnapshotSyncV2AccountScopeToken) async -> Bool {
        guard let application = snapshotSyncV2Application,
              matchesSnapshotSyncV2AccountScope(accountScope),
              !isDocumentTransitionInProgress, !isTerminationPending,
              interactiveAuthOperationCount == 0 else { return false }
        cancelSnapshotSyncV2BackgroundOperations()
        let prepared = await documentOperationGate.perform { [weak self] in
            guard let self, matchesSnapshotSyncV2AccountScope(accountScope),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            do {
                let result = try await saveCoordinator.performExclusiveAfterFlushing {
                    guard matchesSnapshotSyncV2AccountScope(accountScope) else { throw SyncV2ApplicationError.safeBoundaryRejected }
                    _ = try await application.prepareWorkDeletion(workID: work.workID)
                    guard matchesSnapshotSyncV2AccountScope(accountScope) else { throw SyncV2ApplicationError.safeBoundaryRejected }
                    if currentSnapshotSyncV2WorkID == work.workID {
                        document = NovelDocument.newDocument()
                        snapshotSyncV2ActiveWorkID = nil
                        snapshotSyncV2Session = nil
                        snapshotSyncV2Attachments = []
                        snapshotSyncV2Resources = []
                        snapshotSyncV2PortableCreatedAt = nil
                        attachments = []
                        attachmentPreviewURLs.removeAll()
                        selectedChapterID = nil
                        selectedEpisodeID = nil
                        selectedCharacterID = nil
                        selectedPlotCardID = nil
                        selectedFlagID = nil
                        selectedWorldNoteID = nil
                        editorContentGeneration &+= 1
                        documentSessionToken = AppDocumentSessionToken(
                            generation: editorContentGeneration,
                            documentID: document.id,
                            workID: WorkID(UUID())
                        )
                        snapshotSyncHistory = []
                        snapshotSyncV2UIState = nil
                        saveState = .saved
                        userDefaults.removeObject(forKey: "fuminiwa.v2.activeWorkID")
                        userDefaults.set(true, forKey: "fuminiwa.v2.startInLibrary")
                        startupState = .documentSelection(.init(
                            works: snapshotSyncLibraryWorks,
                            presentation: .localAndRemote,
                            connection: lastStartupLibraryConnection
                        ))
                    }
                }
                guard case .completed = result else {
                    operationMessage = "保存できなかったため削除を中止しました。原稿を保持しています。保存を再試行してください。"
                    return false
                }
                return true
            } catch {
                operationMessage = "削除を開始できませんでした。対象作品のアカウントでサインインして再試行してください。"
                return false
            }
        }
        guard prepared else { return false }
        do {
            try await application.deleteWork(workID: work.workID)
            guard matchesSnapshotSyncV2AccountScope(accountScope) else { return false }
            snapshotSyncRemoteCatalogItems.removeAll { $0.workID == work.workID }
            snapshotSyncLibraryWorks.removeAll { $0.workID == work.workID }
            await refreshSnapshotLibrary()
            return true
        } catch {
            guard matchesSnapshotSyncV2AccountScope(accountScope) else { return false }
            operationMessage = "削除はまだ完了していません。端末のデータを保持して削除待ちにしました。接続時に再試行します。右クリックの「削除…」からも再試行できます。"
            await refreshSnapshotLibrary()
            return false
        }
    }
}
