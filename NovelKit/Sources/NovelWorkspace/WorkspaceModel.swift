import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import Observation

/// Shared in-memory state. OS lifecycle, gates and presentation lifetimes stay
/// with the adapters; this model does not perform saves or network operations.
@MainActor
@Observable
public final class WorkspaceModel {
    public var document: NovelDocument
    public var selectedChapterID: ChapterID?
    public var selectedEpisodeID: EpisodeID?
    public var documentSessionToken: WorkspaceSessionToken
    public var activeWorkID: WorkID?
    public var editorContentGeneration: UInt64 = 0
    public var editGeneration: UInt64 = 0
    public var accountGeneration: UInt64 = 0
    public var authSession: FuminiwaSession?
    public var authUIState: WorkspaceAuthUIState = .unavailable
    public var saveState: WorkspaceSaveState
    public var syncUIState: SyncUIState?
    public var syncConflict: SyncV2ConflictProjection?
    public var isSyncInFlight = false
    public var isDocumentTransitionInProgress = false
    public var attachments: [Attachment] = []
    @ObservationIgnored public var attachmentSet = WorkspaceAttachmentSet()
    public var libraryRows: [SyncV2LibraryItem] = []
    public var libraryIsLoading = false
    public var libraryFailure: SyncV2Failure?
    public var remoteCatalogItems: [SyncV2RemoteCatalogEntry] = []
    public var remoteCatalogCursor: String?
    public var pendingDeletionWorkIDs: Set<WorkID> = []
    public var libraryImportPhases: [WorkID: ImportPhase] = [:]
    public var libraryImportFailures: [WorkID: SyncV2Failure] = [:]
    public var historyItems: [SyncV2HistoryItem] = []
    public var keepBothHandoff: WorkspaceKeepBothHandoff?
    public var keepBothPendingWorkID: WorkID?
    @ObservationIgnored public var presentedSyncFailures: [WorkspaceAccountScope: [WorkID: SyncV2FatalReason]] = [:]
    @ObservationIgnored public var automaticAdoptionAttempts: [WorkspaceAccountScope: [WorkID: Set<UUID>]] = [:]
    public let assistantRequestCenter: AssistantRequestCenter

    public init(document: NovelDocument, session: WorkspaceSessionToken, saveState: WorkspaceSaveState,
                assistantRequestCenter: AssistantRequestCenter = AssistantRequestCenter()) {
        self.document = document
        selectedChapterID = document.chapters.first?.id
        selectedEpisodeID = document.chapters.first?.episodes.first?.id
        documentSessionToken = session
        self.saveState = saveState
        self.assistantRequestCenter = assistantRequestCenter
    }

    public var accountScope: WorkspaceAccountScope {
        accountScope(serverInstanceID: authSession?.serverInstanceID.uuidString.lowercased())
    }

    /// The adapter supplies its test-composition server override, if any.
    public func accountScope(serverInstanceID: String?) -> WorkspaceAccountScope {
        WorkspaceAccountScope(
            accountID: authSession?.accountID, accountFence: authSession?.accountFence,
            serverInstanceID: serverInstanceID,
            protocolEpoch: authSession.flatMap { Int64(exactly: $0.syncProtocolEpoch) },
            generation: accountGeneration
        )
    }

    /// iOS has no installed session while its shelf is active. Its existing
    /// payload-derived token projection is retained independently of startup UI.
    public var activeDocumentSessionToken: WorkspaceSessionToken? {
        activeWorkID.map {
            WorkspaceSessionToken(generation: documentSessionToken.generation, documentID: document.id, workID: $0)
        }
    }
}
