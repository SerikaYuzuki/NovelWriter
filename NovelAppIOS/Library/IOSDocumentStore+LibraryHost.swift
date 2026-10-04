import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore: WorkspaceLibraryHost {
    var projectsDeletionBeforeSending: Bool {
        true
    }

    var permitsLibraryLocalCompletion: Bool {
        !isSyncV2AccountTransitionActive
    }

    var permitsLibraryDeletionSending: Bool {
        !isSyncV2RemoteAccountTransitionActive
    }

    func permitsLibraryMutation(_ mutation: WorkspaceLibraryMutation, workID: WorkID) -> Bool {
        guard workspaceModel.keepBothPendingWorkID == nil || workID != workspaceModel.activeWorkID else { return false }
        return switch mutation {
        case .rename: !isSyncV2AccountTransitionActive
        case .deletion: libraryDeletionDisabledReason(for: workID) == nil
        }
    }

    func libraryMutationBoundary(
        _ mutation: WorkspaceLibraryMutation, workID: WorkID, context: WorkspaceOperationContext,
        operation: @MainActor () async throws -> Void
    ) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self, LibraryCoordinator.matches(context, host: self),
                  permitsLibraryMutation(mutation, workID: workID) else { return false }
            return await performDocumentTransition {
                try await saveCoordinator.performExclusive { try await operation() }
            }
        }
    }

    func cancelLibraryBackgroundOperations() {
        cancelSnapshotSyncV2BackgroundOperations()
    }

    func refreshWorkspaceLibrary() async {
        _ = await refreshLibrary()
    }

    func removeDeletedLibraryWork(_ workID: WorkID) {
        workspaceModel.remoteCatalogItems.removeAll { $0.workID == workID }
    }

    func willSendLibraryDeletion(_ workID: WorkID) {
        workspaceModel.assistantRequestCenter.cancel(work: workID.rawValue)
    }

    func retireLibraryWork(_ workID: WorkID) {
        if workspaceModel.activeWorkID == workID {
            retireDeletedWork()
        }
    }

    private func retireDeletedWork() {
        startupState = .library
        workspaceModel.activeWorkID = nil
        clearKeepBothHandoff()
        workspaceModel.document = NovelDocument.newDocument()
        workspaceModel.documentSessionToken.documentID = workspaceModel.document.id
        documentURL = libraryRoot
        replaceAttachments([])
        workspaceModel.attachmentSet = WorkspaceAttachmentSet()
        syncV2PortableResources = []
        syncV2PortableCreatedAt = nil
        workspaceModel.selectedChapterID = nil
        workspaceModel.selectedEpisodeID = nil
        workspaceModel.historyItems = []
        syncV2HistoryWorkID = nil
        syncV2HistoryCursor = nil
        syncV2HistoryLocalAvailability = .unavailable
        syncV2HistoryOnlineAvailability = .unavailable
        syncV2HistoryOnlineFailure = nil
        workspaceModel.syncConflict = nil
        workspaceModel.syncUIState = nil
        snapshotSyncOutcome = nil
        advanceDocumentSessionGeneration()
        advanceEditorContentGeneration()
        workspaceModel.saveState = .saved
        userDefaults.removeObject(forKey: Self.lastWorkIDKey)
    }
}
