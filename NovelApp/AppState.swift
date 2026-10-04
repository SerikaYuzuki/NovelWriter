import AppKit
import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelTiming
import NovelWorkspace
import NovelWorkspaceUI
import NovelWritingProgress
import NovelWritingSupport
import Observation

typealias DocumentSaveState = WorkspaceSaveState
typealias AuthUIState = WorkspaceAuthUIState

final class NotificationObserverToken {
    private let center: NotificationCenter
    var value: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    deinit {
        if let value {
            center.removeObserver(value)
        }
    }
}

@MainActor
@Observable
final class AppState {
    let syncSessionController = SyncSessionController<Bool>()
    let timing: FuminiwaTiming
    let assistantRequestCenter = AssistantRequestCenter()
    let writingSyncScheduler: WritingSyncScheduler
    let writingProgress: WritingProgressTracker
    let writingProgressRoot: URL?
    var document: NovelDocument
    var selectedChapterID: ChapterID?
    var selectedEpisodeID: EpisodeID?
    var selectedCharacterID: CharacterID?
    var selectedPlotCardID: PlotCardID?
    var selectedFlagID: FlagID?
    var selectedWorldNoteID: WorldNoteID?
    var plotOutlineSelection: PlotOutlineSelection = .unassigned

    var saveState: DocumentSaveState
    var startupState: AppStartupState {
        didSet { logStartupTransition(from: oldValue) }
    }

    var lastStartupLibraryConnection: StartupLibraryConnection = .offline
    #if FUMINIWA_TEST_COMPOSITION
    @ObservationIgnored var testServerInstanceIDOverride: String?
    @ObservationIgnored var testBrowserAuthorization: (@MainActor @Sendable (URL) async throws -> Void)?
    #endif
    var authSession: FuminiwaSession?
    var authUIState: AuthUIState
    var snapshotSyncPendingDeletionWorkIDs: Set<WorkID> = []
    var snapshotSyncV2UIState: SyncUIState?
    @ObservationIgnored var presentedSyncFailures: [WorkspaceAccountScope: [WorkID: SyncV2FatalReason]] = [:]
    @ObservationIgnored var automaticAdoptionAttempts: [WorkspaceAccountScope: [WorkID: Set<UUID>]] = [:]
    var snapshotSyncConflict: SyncV2ConflictProjection?
    var snapshotSyncHistory: [SyncV2HistoryItem] = []
    var snapshotSyncHistoryLoading = false
    var snapshotSyncHistoryFailure: String?
    @ObservationIgnored var snapshotSyncHistoryRevision = UUID()
    var snapshotSyncLibraryWorks: [StartupLibraryWork] = []
    var snapshotSyncRemoteCatalogNextCursor: String?
    var snapshotSyncRemoteCatalogItems: [SyncV2RemoteCatalogEntry] = []
    var snapshotSyncCurrentWorkAccountState: SyncV2LibraryAccountState?
    @ObservationIgnored var writingMCPControllerStorage: WritingMCPController?
    var manuscriptCopyNotice: ManuscriptCopyNotice?
    var isSnapshotSyncInFlight = false
    var externalDocumentOpenErrorMessage: String?
    var operationMessage: String?
    var isDocumentTransitionInProgress = false
    var isTerminationPending = false

    var workspaceSelection: WorkspaceSelection {
        didSet {
            userDefaults.set(workspaceSelection.section.rawValue, forKey: Self.projectSectionKey)
        }
    }

    let workSearch = WorkSearchSession()

    var outlinePresentation = OutlinePresentationState()
    var attachments: [Attachment]
    @ObservationIgnored var workspaceAttachments = WorkspaceAttachmentSet()
    var snapshotSyncV2Attachments: [SyncAttachment] {
        get { workspaceAttachments.records }
        set {
            if let replacement = WorkspaceAttachmentSet(newValue) {
                workspaceAttachments = replacement
            }
        }
    }

    @ObservationIgnored var attachmentPreviewURLs: [String: URL]

    var documentSessionToken: WorkspaceSessionToken
    var syncV2KeepBothHandoff: WorkspaceKeepBothHandoff?
    var syncV2KeepBothSourceSelection: SnapshotSyncV2ConflictSelection?
    var syncV2KeepBothPendingWorkID: WorkID?
    var editorContentGeneration: UInt64

    let portableBridge: SyncV2PortableBridge
    let userDefaults: UserDefaults
    let fileManager: FileManager
    let defaultDocumentDirectoryName: String
    let editorCommandSession: EditorCommandSession
    let clipboardWriter: any PlainTextClipboardWriting
    let activeCommittedTextCapture: @MainActor () -> EditorCommittedTextCaptureResult
    let browserAuthorization: @MainActor @Sendable (URL) async throws -> Void
    let authSessionCoordinator: AuthSessionCoordinator?
    let appleSignInCoordinator: AppleSignInCoordinator?
    let appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator?
    let snapshotSyncV2Factory: (@Sendable () async throws -> SyncV2Application)?
    let snapshotSyncV2DocumentGate: MacSyncV2DocumentGate?
    #if FUMINIWA_TEST_COMPOSITION
    let snapshotSyncV2CheckpointOverride: SnapshotSyncV2CheckpointOverride?
    let snapshotSyncV2OpenOverride: SnapshotSyncV2OpenOverride?
    let snapshotSyncV2OpenLocalOverride: SnapshotSyncV2OpenLocalOverride?
    let snapshotSyncV2LibraryOverride: SnapshotSyncV2LibraryOverride?
    let snapshotSyncV2CatalogOverride: SnapshotSyncV2CatalogOverride?
    var snapshotSyncV2KeepBothInstallOverride: (@MainActor () async -> Bool)?
    var snapshotSyncV2BeforeKeepBothInstallOverride: (@MainActor () async -> Void)?
    let snapshotSyncV2AfterStagedRemoteOverride: SnapshotSyncV2AfterStagedRemoteOverride?
    #endif

    @ObservationIgnored var snapshotSyncV2Application: SyncV2Application?
    @ObservationIgnored var snapshotSyncV2Session: NovelSyncV2Application.DocumentSessionToken?
    @ObservationIgnored var snapshotSyncV2ActiveWorkID: WorkID?
    @ObservationIgnored var snapshotSyncV2DocumentCreatedAt: Date?
    @ObservationIgnored var snapshotSyncV2PortableCreatedAt: Date?
    @ObservationIgnored var snapshotSyncV2Resources: [PortableResource]
    var libraryImportPhases: [WorkID: ImportPhase] = [:]
    var libraryImportFailures: [WorkID: SyncV2Failure] = [:]
    var snapshotSyncLibraryFailure: SyncV2Failure?
    var snapshotSyncLibraryLocalFailure: SyncV2Failure?
    var snapshotSyncLibraryOpenFailure: SyncV2Failure?
    var snapshotSyncLibraryIsLoading = false
    @ObservationIgnored var snapshotSyncV2CatalogRefreshToken: UUID?
    #if FUMINIWA_TEST_COMPOSITION
    @ObservationIgnored var documentOperationDidEnqueue: (@MainActor () -> Void)?
    @ObservationIgnored lazy var documentOperationGate = DocumentOperationGate(didEnqueueOperation: { [weak self] in
        self?.documentOperationDidEnqueue?()
    })
    #else
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    #endif
    @ObservationIgnored let authOperationGate = AuthOperationGate()
    /// Counts interactive auth requests from invocation until the serialized
    /// operation fully commits. This is separate from the presentation-only
    /// `authUIState` so queued requests close replacement boundaries early.
    @ObservationIgnored var interactiveAuthOperationCount = 0
    @ObservationIgnored var interactiveAuthOperationOwners: Set<UUID> = []
    /// Represents the one queued or active interactive Apple sign-in request.
    /// It is deliberately independent from `interactiveAuthOperationCount`:
    /// a request waiting behind sign-out must not block local work, while a
    /// duplicate tap must not enqueue a second Apple exchange.
    @ObservationIgnored var pendingSignInRequest = false
    @ObservationIgnored var terminationTask: Task<Bool, Never>?
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var manuscriptCopyNoticeDismissTask: Task<Void, Never>?
    @ObservationIgnored var hasCompletedBootstrap = false
    var documentChangeRevision: UInt64 = 0
    @ObservationIgnored var editorProgressAlreadyTracked = false
    @ObservationIgnored var saveCoordinator: V2DocumentSaveCoordinator!
    @ObservationIgnored let resignActiveObserver = NotificationObserverToken()
    @ObservationIgnored let systemSleepObserver = NotificationObserverToken(center: NSWorkspace.shared.notificationCenter)
    @ObservationIgnored let becomeActiveObserver = NotificationObserverToken()
    @ObservationIgnored let systemWakeObserver = NotificationObserverToken(center: NSWorkspace.shared.notificationCenter)

    static let projectSectionKey = AppPreferenceKey.projectSection

    var usesSnapshotSyncV2Runtime: Bool {
        snapshotSyncV2Application != nil || snapshotSyncV2Factory != nil
    }

    /// Compatibility names used by old menu wiring are deliberately v2-only.
    var permitsDocumentInteraction: Bool {
        startupState.isReady && !isDocumentTransitionInProgress && !isTerminationPending
            && syncV2KeepBothPendingWorkID == nil
    }

    var permitsDocumentChoice: Bool {
        startupState.isReady && !isDocumentTransitionInProgress && !isTerminationPending
            && syncV2KeepBothPendingWorkID == nil
    }

    /// Leaving a frozen source is permitted without making it writable.
    var permitsDocumentDeparture: Bool {
        startupState.isReady && !isDocumentTransitionInProgress && !isTerminationPending
            && interactiveAuthOperationCount == 0
    }

    /// Replacing/exporting/restoring a document must not race the Apple
    /// exchange. Local editor edits and checkpoints remain permitted while
    /// this transition-only boundary is closed.
    var permitsDocumentTransitionOperation: Bool {
        permitsDocumentInteraction && interactiveAuthOperationCount == 0
    }

    var canExplicitlySyncCurrentWork: Bool {
        permitsDocumentTransitionOperation && !isSnapshotSyncInFlight
    }

    var canCloneCurrentWorkIntoActiveAccount: Bool {
        permitsDocumentTransitionOperation && isSignedInToFuminiwa
            && snapshotSyncCurrentWorkAccountState == .unbound
    }

    var selectedChapter: Chapter? {
        guard let selectedChapterID else { return nil }
        return document.chapters.first { $0.id == selectedChapterID }
    }

    var selectedEpisode: Episode? {
        guard let selectedEpisodeID else { return nil }
        return selectedChapter?.episodes.first { $0.id == selectedEpisodeID }
    }

    init(
        dependencies: AppDependencies,
        initialStartupState: AppStartupState = .loading
    ) {
        let timing = FuminiwaTiming(defaults: dependencies.userDefaults)
        self.timing = timing
        writingSyncScheduler = WritingSyncScheduler(timing: timing)
        writingProgress = WritingProgressTracker(defaults: dependencies.userDefaults, timing: timing)
        writingProgressRoot = dependencies.writingProgressRoot
        portableBridge = dependencies.portableBridge
        userDefaults = dependencies.userDefaults
        fileManager = dependencies.fileManager
        defaultDocumentDirectoryName = dependencies.defaultDocumentDirectoryName
        editorCommandSession = dependencies.editorCommandSession
        clipboardWriter = dependencies.clipboardWriter
        activeCommittedTextCapture = dependencies.activeCommittedTextCapture
        browserAuthorization = dependencies.browserAuthorization
        authSessionCoordinator = dependencies.authSessionCoordinator
        appleSignInCoordinator = dependencies.appleSignInCoordinator
        appleAuthenticationOrchestrator = dependencies.appleAuthenticationOrchestrator
        snapshotSyncV2Factory = dependencies.snapshotSyncV2Factory
        snapshotSyncV2DocumentGate = dependencies.snapshotSyncV2DocumentGate
        #if FUMINIWA_TEST_COMPOSITION
        snapshotSyncV2CheckpointOverride = dependencies.snapshotSyncV2CheckpointOverride
        snapshotSyncV2OpenOverride = dependencies.snapshotSyncV2OpenOverride
        snapshotSyncV2OpenLocalOverride = dependencies.snapshotSyncV2OpenLocalOverride
        snapshotSyncV2LibraryOverride = dependencies.snapshotSyncV2LibraryOverride
        snapshotSyncV2CatalogOverride = dependencies.snapshotSyncV2CatalogOverride
        snapshotSyncV2AfterStagedRemoteOverride = dependencies.snapshotSyncV2AfterStagedRemoteOverride
        #endif

        let placeholder = NovelDocument.newDocument()
        document = placeholder
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        selectedCharacterID = nil
        selectedPlotCardID = nil
        selectedFlagID = nil
        selectedWorldNoteID = nil
        plotOutlineSelection = placeholder.chapters.first.map { .chapter($0.id) } ?? .unassigned
        saveState = .unsaved
        startupState = initialStartupState
        authSession = nil
        authUIState = dependencies.authSessionCoordinator == nil ? .unavailable : .signedOut
        externalDocumentOpenErrorMessage = nil
        operationMessage = nil
        attachments = []
        snapshotSyncV2Resources = []
        snapshotSyncV2PortableCreatedAt = nil
        attachmentPreviewURLs = [:]
        snapshotSyncLibraryWorks = []
        snapshotSyncRemoteCatalogItems = []
        snapshotSyncCurrentWorkAccountState = nil
        manuscriptCopyNotice = nil
        documentSessionToken = WorkspaceSessionToken(
            generation: 0,
            documentID: placeholder.id,
            workID: WorkID(UUID())
        )
        editorContentGeneration = 0
        let storedSection = dependencies.userDefaults.string(forKey: Self.projectSectionKey) ?? ""
        let normalizedSection = storedSection == "planning" ? ProjectSection.projectInfo.rawValue : storedSection
        if storedSection == "planning" {
            dependencies.userDefaults.set(normalizedSection, forKey: Self.projectSectionKey)
        }
        workspaceSelection = WorkspaceSelection(
            section: ProjectSection(rawValue: normalizedSection) ?? .structure
        )

        saveCoordinator = V2DocumentSaveCoordinator(
            timing: timing,
            currentDocument: { [weak self] in
                guard let self, startupState.isReady else { return nil }
                return document
            },
            saveOperation: { [weak self] document in
                guard let self else { throw CancellationError() }
                guard await checkpointSnapshotSyncV2(document, reason: .autosave, acknowledgeLocalCommit: true) else {
                    throw SyncV2Failure.fatal(.invalidLocalState)
                }
            },
            saveEventHandler: WorkspaceSaveEventProjection.handler(host: self) { [weak self] event in
                self?.handleSaveEvent(event)
            }
        )

        // Foreground/wake are local lifecycle hints only. They wake the
        // shared outbox in a detached Task and never hold the editor on a
        // network response.
        becomeActiveObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.resumeSnapshotSyncV2()
            }
        }
        systemWakeObserver.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.resumeSnapshotSyncV2(reason: .systemWake)
            }
        }
    }
}
