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
        switch mutation {
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
        syncV2RemoteCatalogItems.removeAll { $0.workID == workID }
    }

    func willSendLibraryDeletion(_ workID: WorkID) {
        assistantRequestCenter.cancel(work: workID.rawValue)
    }

    func retireLibraryWork(_ workID: WorkID) {
        if syncV2ActiveWorkID == workID {
            retireDeletedWork()
        }
    }

    private func retireDeletedWork() {
        startupState = .library
        syncV2ActiveWorkID = nil
        syncV2KeepBothPendingWorkID = nil
        document = NovelDocument.newDocument()
        documentURL = libraryRoot
        replaceAttachments([])
        workspaceAttachments = WorkspaceAttachmentSet()
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
