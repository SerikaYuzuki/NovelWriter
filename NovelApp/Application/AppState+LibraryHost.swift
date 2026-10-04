import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension AppState: WorkspaceLibraryHost {
    var projectsDeletionBeforeSending: Bool {
        false
    }

    var permitsLibraryLocalCompletion: Bool {
        true
    }

    var permitsLibraryDeletionSending: Bool {
        true
    }

    func permitsLibraryMutation(_: WorkspaceLibraryMutation, workID: WorkID) -> Bool {
        !isDocumentTransitionInProgress && !isTerminationPending && interactiveAuthOperationCount == 0
            && (syncV2KeepBothPendingWorkID == nil || workID != currentSnapshotSyncV2WorkID)
    }

    func libraryMutationBoundary(
        _ mutation: WorkspaceLibraryMutation, workID: WorkID, context: WorkspaceOperationContext,
        operation: @MainActor () async throws -> Void
    ) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self, LibraryCoordinator.matches(context, host: self),
                  permitsLibraryMutation(mutation, workID: workID),
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            do {
                switch mutation {
                case .rename:
                    if saveState != .saved {
                        guard await saveNow() else { return false }
                    }
                    try await saveCoordinator.performExclusive { try await operation() }
                case .deletion:
                    let result = try await saveCoordinator.performExclusiveAfterFlushing { try await operation() }
                    guard case .completed = result else {
                        operationMessage = "保存できなかったため削除を中止しました。原稿を保持しています。保存を再試行してください。"
                        return false
                    }
                }
                return true
            } catch {
                switch mutation {
                case .rename:
                    operationMessage = "作品名を変更できませんでした。一覧を更新して再試行してください。"
                case .deletion:
                    operationMessage = "削除を開始できませんでした。対象作品のアカウントでサインインして再試行してください。"
                }
                return false
            }
        }
    }

    func cancelLibraryBackgroundOperations() {
        cancelSnapshotSyncV2BackgroundOperations()
    }

    func refreshWorkspaceLibrary() async {
        await refreshSnapshotLibrary()
    }

    func removeDeletedLibraryWork(_ workID: WorkID) {
        snapshotSyncRemoteCatalogItems.removeAll { $0.workID == workID }
        snapshotSyncLibraryWorks.removeAll { $0.workID == workID }
    }

    func willSendLibraryDeletion(_ workID: WorkID) {
        assistantRequestCenter.cancel(work: workID.rawValue)
    }

    func retireLibraryWork(_ workID: WorkID) {
        if currentSnapshotSyncV2WorkID == workID {
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
            documentSessionToken = WorkspaceSessionToken(
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
}
