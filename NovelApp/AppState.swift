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
    let workspaceModel: WorkspaceModel
    let syncSessionController = SyncSessionController<Bool>()
    let timing: FuminiwaTiming
    let writingSyncScheduler: WritingSyncScheduler
    let writingProgress: WritingProgressTracker
    let writingProgressRoot: URL?
    var selectedCharacterID: CharacterID?
    var selectedPlotCardID: PlotCardID?
    var selectedFlagID: FlagID?
    var selectedWorldNoteID: WorldNoteID?
    var plotOutlineSelection: PlotOutlineSelection = .unassigned

    var startupState: AppStartupState {
        didSet { logStartupTransition(from: oldValue) }
    }

    var lastStartupLibraryConnection: StartupLibraryConnection = .offline
    #if FUMINIWA_TEST_COMPOSITION
    @ObservationIgnored var testServerInstanceIDOverride: String?
    @ObservationIgnored var testBrowserAuthorization: (@MainActor @Sendable (URL) async throws -> Void)?
    #endif
    var snapshotSyncHistoryLoading = false
    var snapshotSyncHistoryFailure: String?
    @ObservationIgnored var snapshotSyncHistoryRevision = UUID()
    @ObservationIgnored var startupShelfIdentities: [(workID: WorkID, id: UUID, availability: StartupLibraryWorkAvailability)] = []

    var snapshotSyncCurrentWorkAccountState: SyncV2LibraryAccountState?
    @ObservationIgnored var writingMCPControllerStorage: WritingMCPController?
    var manuscriptCopyNotice: ManuscriptCopyNotice?
    var externalDocumentOpenErrorMessage: String?
    var operationMessage: String?
    var isTerminationPending = false

    var workspaceSelection: WorkspaceSelection {
        didSet {
            userDefaults.set(workspaceSelection.section.rawValue, forKey: Self.projectSectionKey)
        }
    }

    let workSearch = WorkSearchSession()

    var outlinePresentation = OutlinePresentationState()
    var snapshotSyncV2Attachments: [SyncAttachment] {
        get { workspaceModel.attachmentSet.records }
        set {
            if let replacement = WorkspaceAttachmentSet(newValue) {
                workspaceModel.attachmentSet = replacement
            }
        }
    }

    @ObservationIgnored var attachmentPreviewURLs: [String: URL]

    var syncV2KeepBothSourceSelection: SnapshotSyncV2ConflictSelection?

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
    @ObservationIgnored var snapshotSyncV2DocumentCreatedAt: Date?
    @ObservationIgnored var snapshotSyncV2PortableCreatedAt: Date?
    @ObservationIgnored var snapshotSyncV2Resources: [PortableResource]
    var snapshotSyncLibraryLocalFailure: SyncV2Failure?
    var snapshotSyncLibraryOpenFailure: SyncV2Failure?
    @ObservationIgnored var snapshotSyncV2CatalogRefreshToken: UUID?
    #if FUMINIWA_TEST_COMPOSITION
    @ObservationIgnored var documentOperationDidEnqueue: (@MainActor () -> Void)?
    @ObservationIgnored lazy var documentOperationGate = DocumentOperationGate(didEnqueueOperation: { [weak self] in
        self?.documentOperationDidEnqueue?()
    })
    #else
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    #endif
    @ObservationIgnored lazy var accountTransitionCoordinator = AccountTransitionCoordinator(host: self)
    var interactiveAuthOperationCount: Int {
        accountTransitionCoordinator.preparing || accountTransitionCoordinator.inProgress ? 1 : 0
    }

    var authRevokeRetryTask: Task<Void, Never>? {
        accountTransitionCoordinator.revokeTask
    }

    @ObservationIgnored var terminationTask: Task<Bool, Never>?
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var manuscriptCopyNoticeDismissTask: Task<Void, Never>?
    @ObservationIgnored var hasCompletedBootstrap = false
    @ObservationIgnored var editorProgressAlreadyTracked = false
    @ObservationIgnored var saveCoordinator: V2DocumentSaveCoordinator!
    @ObservationIgnored let resignActiveObserver = NotificationObserverToken()
    @ObservationIgnored let systemSleepObserver = NotificationObserverToken(center: NSWorkspace.shared.notificationCenter)
    @ObservationIgnored let becomeActiveObserver = NotificationObserverToken()
    @ObservationIgnored let systemWakeObserver = NotificationObserverToken(center: NSWorkspace.shared.notificationCenter)

    static let projectSectionKey = AppPreferenceKey.projectSection

    /// Compatibility names used by old menu wiring are deliberately v2-only.
    var permitsDocumentInteraction: Bool {
        startupState.isReady && !workspaceModel.isDocumentTransitionInProgress && !isTerminationPending
            && workspaceModel.keepBothPendingWorkID == nil
    }

    var permitsDocumentChoice: Bool {
        startupState.isReady && !workspaceModel.isDocumentTransitionInProgress && !isTerminationPending
            && workspaceModel.keepBothPendingWorkID == nil
    }

    /// Leaving a frozen source is permitted without making it writable.
    var permitsDocumentDeparture: Bool {
        startupState.isReady && !workspaceModel.isDocumentTransitionInProgress && !isTerminationPending
            && interactiveAuthOperationCount == 0
    }

    /// Replacing/exporting/restoring a document must not race the Apple
    /// exchange. Local editor edits and checkpoints remain permitted while
    /// this transition-only boundary is closed.
    var permitsDocumentTransitionOperation: Bool {
        permitsDocumentInteraction && interactiveAuthOperationCount == 0
    }

    var canExplicitlySyncCurrentWork: Bool {
        permitsDocumentTransitionOperation && !workspaceModel.isSyncInFlight
    }

    var canCloneCurrentWorkIntoActiveAccount: Bool {
        permitsDocumentTransitionOperation && isSignedInToFuminiwa
            && snapshotSyncCurrentWorkAccountState == .unbound
    }

    var selectedChapter: Chapter? {
        guard let selectedChapterID = workspaceModel.selectedChapterID else { return nil }
        return workspaceModel.document.chapters.first { $0.id == selectedChapterID }
    }

    var selectedEpisode: Episode? {
        guard let selectedEpisodeID = workspaceModel.selectedEpisodeID else { return nil }
        return selectedChapter?.episodes.first { $0.id == selectedEpisodeID }
    }

    init(
        dependencies: AppDependencies,
        initialStartupState: AppStartupState = .loading
    ) {
        let placeholder = NovelDocument.newDocument()
        workspaceModel = WorkspaceModel(
            document: placeholder,
            session: WorkspaceSessionToken(generation: 0, documentID: placeholder.id, workID: WorkID(UUID())),
            saveState: .unsaved
        )
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

        selectedCharacterID = nil
        selectedPlotCardID = nil
        selectedFlagID = nil
        selectedWorldNoteID = nil
        plotOutlineSelection = placeholder.chapters.first.map { .chapter($0.id) } ?? .unassigned
        startupState = initialStartupState
        externalDocumentOpenErrorMessage = nil
        operationMessage = nil
        snapshotSyncV2Resources = []
        snapshotSyncV2PortableCreatedAt = nil
        attachmentPreviewURLs = [:]
        snapshotSyncCurrentWorkAccountState = nil
        manuscriptCopyNotice = nil
        let storedSection = dependencies.userDefaults.string(forKey: Self.projectSectionKey) ?? ""
        let normalizedSection = storedSection == "planning" ? ProjectSection.projectInfo.rawValue : storedSection
        if storedSection == "planning" {
            dependencies.userDefaults.set(normalizedSection, forKey: Self.projectSectionKey)
        }
        workspaceSelection = WorkspaceSelection(
            section: ProjectSection(rawValue: normalizedSection) ?? .structure
        )

        workspaceModel.authUIState = dependencies.authSessionCoordinator == nil ? .unavailable : .signedOut

        saveCoordinator = V2DocumentSaveCoordinator(
            timing: timing,
            currentDocument: { [weak self] in
                guard let self, startupState.isReady else { return nil }
                return workspaceModel.document
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
