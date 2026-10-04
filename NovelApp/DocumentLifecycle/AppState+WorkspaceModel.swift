import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

/// Compatibility accessors read the observable model, including SwiftUI bindings.
extension AppState {
    var document: NovelDocument {
        get { workspaceModel.document }
        set { workspaceModel.document = newValue }
    }

    var selectedChapterID: ChapterID? {
        get { workspaceModel.selectedChapterID }
        set { workspaceModel.selectedChapterID = newValue }
    }

    var selectedEpisodeID: EpisodeID? {
        get { workspaceModel.selectedEpisodeID }
        set { workspaceModel.selectedEpisodeID = newValue }
    }

    var assistantRequestCenter: AssistantRequestCenter {
        workspaceModel.assistantRequestCenter
    }

    var editorContentGeneration: UInt64 {
        get { workspaceModel.editorContentGeneration }
        set { workspaceModel.editorContentGeneration = newValue }
    }

    var isDocumentTransitionInProgress: Bool {
        get { workspaceModel.isDocumentTransitionInProgress }
        set { workspaceModel.isDocumentTransitionInProgress = newValue }
    }

    var attachments: [Attachment] {
        get { workspaceModel.attachments }
        set { workspaceModel.attachments = newValue }
    }

    var workspaceAttachments: WorkspaceAttachmentSet {
        get { workspaceModel.attachmentSet }
        set { workspaceModel.attachmentSet = newValue }
    }

    var isSnapshotSyncInFlight: Bool {
        get { workspaceModel.isSyncInFlight }
        set { workspaceModel.isSyncInFlight = newValue }
    }

    var snapshotSyncConflict: SyncV2ConflictProjection? {
        get { workspaceModel.syncConflict }
        set { workspaceModel.syncConflict = newValue }
    }

    var libraryImportPhases: [WorkID: ImportPhase] {
        get { workspaceModel.libraryImportPhases }
        set { workspaceModel.libraryImportPhases = newValue }
    }

    var libraryImportFailures: [WorkID: SyncV2Failure] {
        get { workspaceModel.libraryImportFailures }
        set { workspaceModel.libraryImportFailures = newValue }
    }

    var presentedSyncFailures: [WorkspaceAccountScope: [WorkID: SyncV2FatalReason]] {
        get { workspaceModel.presentedSyncFailures }
        set { workspaceModel.presentedSyncFailures = newValue }
    }

    var automaticAdoptionAttempts: [WorkspaceAccountScope: [WorkID: Set<UUID>]] {
        get { workspaceModel.automaticAdoptionAttempts }
        set { workspaceModel.automaticAdoptionAttempts = newValue }
    }

    var syncV2KeepBothHandoff: WorkspaceKeepBothHandoff? {
        get { workspaceModel.keepBothHandoff }
        set { workspaceModel.keepBothHandoff = newValue }
    }

    var syncV2KeepBothPendingWorkID: WorkID? {
        get { workspaceModel.keepBothPendingWorkID }
        set { workspaceModel.keepBothPendingWorkID = newValue }
    }

    var saveState: DocumentSaveState {
        get { workspaceModel.saveState }
        set { workspaceModel.saveState = newValue }
    }

    var authUIState: AuthUIState {
        get { workspaceModel.authUIState }
        set { workspaceModel.authUIState = newValue }
    }

    var authSession: FuminiwaSession? {
        get { workspaceModel.authSession }
        set { workspaceModel.authSession = newValue }
    }

    var documentSessionToken: WorkspaceSessionToken {
        get { workspaceModel.documentSessionToken }
        set { workspaceModel.documentSessionToken = newValue }
    }

    var documentChangeRevision: UInt64 {
        get { workspaceModel.editGeneration }
        set { workspaceModel.editGeneration = newValue }
    }

    var snapshotSyncV2ActiveWorkID: WorkID? {
        get { workspaceModel.activeWorkID }
        set { workspaceModel.activeWorkID = newValue }
    }

    var snapshotSyncV2UIState: SyncUIState? {
        get { workspaceModel.syncUIState }
        set { workspaceModel.syncUIState = newValue }
    }

    var snapshotSyncHistory: [SyncV2HistoryItem] {
        get { workspaceModel.historyItems }
        set { workspaceModel.historyItems = newValue }
    }

    var snapshotSyncPendingDeletionWorkIDs: Set<WorkID> {
        get { workspaceModel.pendingDeletionWorkIDs }
        set { workspaceModel.pendingDeletionWorkIDs = newValue }
    }

    var snapshotSyncRemoteCatalogItems: [SyncV2RemoteCatalogEntry] {
        get { workspaceModel.remoteCatalogItems }
        set { workspaceModel.remoteCatalogItems = newValue }
    }

    var snapshotSyncRemoteCatalogNextCursor: String? {
        get { workspaceModel.remoteCatalogCursor }
        set { workspaceModel.remoteCatalogCursor = newValue }
    }

    var snapshotSyncLibraryIsLoading: Bool {
        get { workspaceModel.libraryIsLoading }
        set { workspaceModel.libraryIsLoading = newValue }
    }

    var snapshotSyncLibraryFailure: SyncV2Failure? {
        get { workspaceModel.libraryFailure }
        set { workspaceModel.libraryFailure = newValue }
    }

    /// Only Mac display identity/availability stays here; all row payload is
    /// owned by the model. Preserve custom IDs and pending/excluded spellings
    /// rather than silently normalizing the old startup presentation.
    var snapshotSyncLibraryWorks: [StartupLibraryWork] {
        get {
            workspaceModel.libraryRows.enumerated().compactMap { index, row in
                guard startupShelfIdentities.indices.contains(index),
                      startupShelfIdentities[index].workID == row.workID else {
                    return Self.startupLibraryWork(row)?.1
                }
                let identity = startupShelfIdentities[index]
                return StartupLibraryWork(
                    id: identity.id, title: row.title, availability: identity.availability,
                    workID: row.workID, remoteProgress: row.remoteProgress,
                    historyBackfillNote: row.historyBackfillNote, oldestUnreceivedAt: row.oldestUnreceivedAt,
                    accountState: row.accountState, remoteHeadConfirmed: row.remoteHeadConfirmed,
                    localGeneration: row.localGeneration
                )
            }
        }
        set {
            startupShelfIdentities = newValue.map { ($0.workID, $0.id, $0.availability) }
            workspaceModel.libraryRows = newValue.map(Self.snapshotLibraryItem)
        }
    }
}
