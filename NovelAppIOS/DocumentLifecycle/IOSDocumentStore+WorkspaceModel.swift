import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

/// Compatibility accessors read the observable model, including SwiftUI bindings.
extension IOSDocumentStore {
    var document: NovelDocument {
        get { workspaceModel.document }
        set {
            workspaceModel.document = newValue
            workspaceModel.documentSessionToken.documentID = newValue.id
        }
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

    var saveState: IOSSaveState {
        get { workspaceModel.saveState }
        set { workspaceModel.saveState = newValue }
    }

    var authUIState: IOSAuthUIState {
        get { workspaceModel.authUIState }
        set { workspaceModel.authUIState = newValue }
    }

    var authSession: FuminiwaSession? {
        get { workspaceModel.authSession }
        set { workspaceModel.authSession = newValue }
    }

    var documentSessionGeneration: UInt64 {
        get { workspaceModel.documentSessionToken.generation }
        set { workspaceModel.documentSessionToken.generation = newValue }
    }

    var localEditGeneration: UInt64 {
        get { workspaceModel.editGeneration }
        set { workspaceModel.editGeneration = newValue }
    }

    var syncV2ActiveWorkID: WorkID? {
        get { workspaceModel.activeWorkID }
        set {
            workspaceModel.activeWorkID = newValue
            if let newValue {
                workspaceModel.documentSessionToken.workID = newValue
            }
        }
    }

    var snapshotSyncState: SyncUIState? {
        get { workspaceModel.syncUIState }
        set { workspaceModel.syncUIState = newValue }
    }

    var syncV2HistoryItems: [SyncV2HistoryItem] {
        get { workspaceModel.historyItems }
        set { workspaceModel.historyItems = newValue }
    }

    var pendingDeletionWorkIDs: Set<WorkID> {
        get { workspaceModel.pendingDeletionWorkIDs }
        set { workspaceModel.pendingDeletionWorkIDs = newValue }
    }

    var syncV2RemoteCatalogItems: [SyncV2RemoteCatalogEntry] {
        get { workspaceModel.remoteCatalogItems }
        set { workspaceModel.remoteCatalogItems = newValue }
    }

    var syncV2RemoteCatalogCursor: String? {
        get { workspaceModel.remoteCatalogCursor }
        set { workspaceModel.remoteCatalogCursor = newValue }
    }

    var libraryIsLoading: Bool {
        get { workspaceModel.libraryIsLoading }
        set { workspaceModel.libraryIsLoading = newValue }
    }

    var libraryFailure: SyncV2Failure? {
        get { workspaceModel.libraryFailure }
        set { workspaceModel.libraryFailure = newValue }
    }

    var syncV2LibraryItems: [SyncV2LibraryItem] {
        get { workspaceModel.libraryRows }
        set { workspaceModel.libraryRows = newValue }
    }
}
