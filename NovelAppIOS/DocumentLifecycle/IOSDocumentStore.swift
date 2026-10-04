import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime
import NovelTiming
import NovelWorkspace
import NovelWorkspaceUI
import NovelWritingProgress
import NovelWritingSupport
import Observation

enum IOSStartupState: Equatable { case loading, library, ready, recovery(message: String) }
typealias IOSSaveState = WorkspaceSaveState

/// Build-time composition boundary for the app-hosted iOS tests. A Test
/// binary cannot name the production case, while Run/Archive binaries do not
/// contain the fake test composition path.
enum IOSRuntimeComposition: Sendable {
    #if FUMINIWA_TEST_COMPOSITION
    case test(TestRuntimeConfiguration)

    static func currentBuild() -> Self {
        do {
            let configuration = try TestRuntimeConfiguration()
            return .test(configuration)
        } catch {
            preconditionFailure("Unable to create the isolated iOS test runtime: \(error)")
        }
    }
    #else
    case production

    static func currentBuild() -> Self {
        .production
    }
    #endif
}

typealias IOSAuthUIState = WorkspaceAuthUIState

struct IOSEpisodeEditingToken: Hashable, Sendable {
    let documentSession: WorkspaceSessionToken
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
}

struct IOSEditorContentKey: Hashable {
    let documentSession: WorkspaceSessionToken
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
}

struct IOSSnapshotSyncV2ConflictSelection: Equatable, Sendable {
    let workID: WorkID
    let session: WorkspaceSessionToken
    let editGeneration: UInt64
    let accountScope: WorkspaceAccountScope
    let conflict: SyncV2ConflictProjection
}

private struct IOSDocumentStoreAuthComposition {
    let browserAuthorization: @MainActor @Sendable (URL) async throws -> Void
    let sessionVault: (any AuthSessionVault)?
    let sessionCoordinator: AuthSessionCoordinator?
    let appleSignInCoordinator: AppleSignInCoordinator?
    let appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator?
    let uiState: IOSAuthUIState
}

private struct IOSDocumentStoreWorkingCopyComposition {
    let location: IOSPrivateWorkingCopyLocation?
    let root: URL
}

@MainActor
private enum IOSDocumentStoreComposition {
    static func makeAuth(userDefaults: UserDefaults) -> IOSDocumentStoreAuthComposition {
        #if FUMINIWA_TEST_COMPOSITION
        return IOSDocumentStoreAuthComposition(
            browserAuthorization: { try await AuthComposition.authorizeBrowser(url: $0) },
            sessionVault: nil,
            sessionCoordinator: nil,
            appleSignInCoordinator: nil,
            appleAuthenticationOrchestrator: nil,
            uiState: .unavailable
        )
        #else
        let environment = FuminiwaRuntimeEnvironment(userDefaults: userDefaults)
        let url = environment.syncServerURL
        let auth = AuthComposition(
            origin: environment.allowsNetwork && url?.scheme?.lowercased() == "https" ? url : nil,
            keychainService: "dev.serikayuzuki.fuminiwa.sync.ios",
            clientPlatform: .ios,
            appleFlow: .native,
            phaseObserver: { logIOSAppleAuthenticationPhase($0) }
        )
        return IOSDocumentStoreAuthComposition(
            browserAuthorization: auth.browserAuthorization,
            sessionVault: auth.sessionVault,
            sessionCoordinator: auth.sessionCoordinator,
            appleSignInCoordinator: auth.appleSignInCoordinator,
            appleAuthenticationOrchestrator: auth.appleAuthenticationOrchestrator,
            uiState: auth.sessionCoordinator == nil ? .unavailable : .signedOut
        )
        #endif
    }

    static func makeWorkingCopy(
        runtimeComposition: IOSRuntimeComposition,
        privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation?,
        libraryRoot: URL?,
        fileManager: FileManager
    ) -> IOSDocumentStoreWorkingCopyComposition {
        #if FUMINIWA_TEST_COMPOSITION
        guard case let .test(testConfiguration) = runtimeComposition else {
            preconditionFailure("The iOS Test binary requires the isolated test composition")
        }
        let requiredRoot = libraryRoot ?? testConfiguration.localRoot.url
        let location = try? IOSPrivateWorkingCopyLocation.prepareInjectedLibraryRoot(
            requiredRoot,
            fileManager: fileManager
        )
        return IOSDocumentStoreWorkingCopyComposition(
            location: location,
            root: location?.rootURL ?? requiredRoot.standardizedFileURL
        )
        #else
        _ = runtimeComposition
        let location: IOSPrivateWorkingCopyLocation? = if let privateWorkingCopyLocation {
            privateWorkingCopyLocation
        } else if let libraryRoot {
            try? IOSPrivateWorkingCopyLocation.prepareInjectedLibraryRoot(
                libraryRoot,
                fileManager: fileManager
            )
        } else {
            try? IOSPrivateWorkingCopyLocation.prepareDefault(fileManager: fileManager)
        }
        return IOSDocumentStoreWorkingCopyComposition(
            location: location,
            root: location?.rootURL
                ?? libraryRoot?.standardizedFileURL
                ?? IOSDocumentStore.defaultLibraryRoot(fileManager: fileManager)
        )
        #endif
    }
}

@MainActor
@Observable
final class IOSDocumentStore {
    let syncSessionController = SyncSessionController<Void>()
    static let lastDocumentNameKey = "FUMINIWAIOS.lastDocumentName"
    /// v2 reopens by WorkID.  The legacy package-recent key remains available
    /// for explicit import/export compatibility, but is never the v2 identity.
    static let lastWorkIDKey = "FUMINIWAIOS.lastWorkID"
    #if FUMINIWA_TEST_COMPOSITION
    /// Test stores created with the same injected root share one isolated
    /// SQLite composition, so reopen tests exercise persistence rather than a
    /// second unrelated UUID database. Production builds do not contain this
    /// cache or the test runtime configuration type.
    static var testRuntimeApplications: [URL: SyncV2Application] = [:]
    /// Keep the test composition's UUID-backed SQLite root alongside the
    /// application cache. Removing an application for a restart fixture must
    /// recreate the composition from the same TestRuntimeConfiguration;
    /// constructing a fresh configuration would silently point at a new
    /// database even when the iOS library root is unchanged.
    static var testRuntimeConfigurations: [URL: TestRuntimeConfiguration] = [:]
    #endif

    let timing: FuminiwaTiming
    let assistantRequestCenter = AssistantRequestCenter()
    let writingSyncScheduler: WritingSyncScheduler
    let writingProgress: WritingProgressTracker
    var document: NovelDocument
    var documentCreatedAt: Date
    var documentURL: URL
    var selectedChapterID: ChapterID?
    var selectedEpisodeID: EpisodeID?
    var startupState: IOSStartupState = .loading
    var saveState: IOSSaveState = .saved
    var authUIState: IOSAuthUIState = .unavailable
    var showsDocumentTransitionOverlay: Bool {
        isDocumentTransitionInProgress && !isNavigationDepartureInProgress && !isRemoteAdoptionInProgress
    }

    var isRemoteAdoptionInProgress = false
    var isDocumentTransitionInProgress = false
    var isNavigationDepartureInProgress = false
    var documentSessionGeneration: UInt64 = 0
    var editorContentGeneration: UInt64 = 0
    var localEditGeneration: UInt64 = 0
    var isImporterPresented = false
    var pendingExportURL: URL?
    var manuscriptCopyNotice: IOSManuscriptCopyNotice?
    var operationErrorMessage: String?
    var attachments: [Attachment] = []
    var libraryItems: [IOSDocumentLibraryItem] = []
    var deviceSyncStartupFailedSafely = false
    var snapshotSyncOutcome: SyncV2TypedResult?
    var snapshotSyncConflict: SyncV2ConflictProjection?
    /// Set only after a remote-only document has passed the install boundary.
    /// The shelf uses it to navigate after the asynchronous fetch completes.
    var libraryImportPhases: [WorkID: ImportPhase] = [:]
    var libraryImportFailures: [WorkID: SyncV2Failure] = [:]
    var snapshotSyncV2RemoteOnlyOpenFailure: SyncV2Failure?
    var showsConflictSheet = false
    var libraryNotice: String?
    var libraryIsLoading = false
    var libraryFailure: SyncV2Failure?
    var isSnapshotSyncInFlight = false
    var snapshotSyncState: SyncUIState?
    @ObservationIgnored var presentedSyncFailures: [WorkspaceAccountScope: [WorkID: SyncV2FatalReason]] = [:]
    @ObservationIgnored var automaticAdoptionAttempts: [WorkspaceAccountScope: [WorkID: Set<UUID>]] = [:]
    var pendingDeletionWorkIDs: Set<WorkID> = []
    var deletedLibraryWorkIDs: Set<WorkID> = []
    var syncV2LibraryItems: [SyncV2LibraryItem] = []
    var syncV2RemoteCatalogItems: [SyncV2RemoteCatalogEntry] = []
    var syncV2RemoteCatalogCursor: String?
    var syncV2RemoteCatalogIsLoading = false
    var syncV2RemoteCatalogError: SyncV2Failure?
    /// Local SQLite and remote occurrences share one history projection.  A
    /// SnapshotID is not a deduplication key: the same snapshot can have a
    /// different local/remote restore authority.
    var syncV2HistoryItems: [SyncV2HistoryItem] = []
    var syncV2HistoryCursor: String?
    var syncV2HistoryWorkID: WorkID?
    var syncV2HistoryLocalAvailability: SyncV2HistoryAvailability = .unavailable
    var syncV2HistoryOnlineAvailability: SyncV2HistoryAvailability = .unavailable
    var syncV2HistoryOnlineFailure: SyncV2Failure?
    /// A signed-out store keeps local SQLite data intact but parks the former
    /// account's remote projection and active sync status.
    var syncV2ParkedAccountID: String?
    /// WorkID is the sync identity; NovelDocument.id is only its payload
    /// anchor and may differ after import, remote open, keep-both, or clone.
    var syncV2ActiveWorkID: WorkID?
    var syncV2AccountCloneInFlight = false
    /// Keep-both reserves a second WorkID before the remote acknowledgement.
    /// Until the candidate is safely opened, the original editor is read-only
    /// so a later autosave cannot accidentally write the source Work again.
    var syncV2KeepBothHandoff: WorkspaceKeepBothHandoff?
    #if FUMINIWA_TEST_COMPOSITION
    var snapshotSyncV2KeepBothInstallOverride: (@MainActor () async -> Bool)?
    #endif
    var syncV2KeepBothPendingWorkID: WorkID?

    var snapshotSyncV2DisplayedConflictSelection: IOSSnapshotSyncV2ConflictSelection? {
        guard let workID = syncV2ActiveWorkID,
              let session = currentDocumentSessionToken,
              let conflict = snapshotSyncConflict else { return nil }
        return IOSSnapshotSyncV2ConflictSelection(
            workID: workID,
            session: session,
            editGeneration: localEditGeneration,
            accountScope: snapshotSyncV2AccountScope,
            conflict: conflict
        )
    }

    var snapshotSyncV2AccountScope: WorkspaceAccountScope {
        let serverInstanceID: String?
        #if FUMINIWA_TEST_COMPOSITION
        serverInstanceID = testServerInstanceIDOverride
            ?? authSession?.serverInstanceID.uuidString.lowercased()
        #else
        serverInstanceID = authSession?.serverInstanceID.uuidString.lowercased()
        #endif
        return WorkspaceAccountScope(
            accountID: authSession?.accountID,
            accountFence: authSession?.accountFence,
            serverInstanceID: serverInstanceID,
            protocolEpoch: authSession.flatMap { Int64(exactly: $0.syncProtocolEpoch) },
            generation: syncSessionController.accountGeneration
        )
    }

    let workSearch = WorkSearchSession()
    var workTextSelectionRequest: EditorSelectionRequest?
    var workTextSelectionToken: IOSEpisodeEditingToken?

    let editorCommandSession: EditorCommandSession
    /// The only package boundary owned by the iOS app. Normal document
    /// lifecycle and attachment editing never receive a package repository;
    /// this bridge is called only by explicit import/export actions.
    @ObservationIgnored let portableBridge: SyncV2PortableBridge
    @ObservationIgnored let fileManager: FileManager
    @ObservationIgnored let userDefaults: UserDefaults
    @ObservationIgnored let libraryRoot: URL
    @ObservationIgnored let runtimeComposition: IOSRuntimeComposition
    @ObservationIgnored let privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation?
    @ObservationIgnored let backgroundTaskController: any IOSBackgroundTaskControlling
    @ObservationIgnored let clipboardWriter: any IOSPlainTextClipboardWriting
    @ObservationIgnored let browserAuthorization: @MainActor @Sendable (URL) async throws -> Void
    #if FUMINIWA_TEST_COMPOSITION
    @ObservationIgnored var authSessionVault: (any AuthSessionVault)?
    @ObservationIgnored var authSessionCoordinator: AuthSessionCoordinator?
    @ObservationIgnored var appleSignInCoordinator: AppleSignInCoordinator?
    @ObservationIgnored var appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator?
    #else
    @ObservationIgnored let authSessionVault: (any AuthSessionVault)?
    @ObservationIgnored let authSessionCoordinator: AuthSessionCoordinator?
    @ObservationIgnored let appleSignInCoordinator: AppleSignInCoordinator?
    @ObservationIgnored let appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator?
    #endif
    #if FUMINIWA_TEST_COMPOSITION
    /// App-hosted tests use the production sign-in entry point with a
    /// suspended exchange.  The seam is test-composition-only and is not
    /// present in the shipped iOS target.
    @ObservationIgnored var testBrowserAuthorization: (@MainActor @Sendable (URL) async throws -> Void)?
    @ObservationIgnored var testAppleSignInHandler: (@MainActor () async throws -> FuminiwaSession)?
    /// The test runtime's scope resolver uses a fixed server namespace. This
    /// override keeps the adapter test aligned with that isolated runtime;
    /// production always uses the session's attested UUID.
    @ObservationIgnored var testServerInstanceIDOverride: String?
    #endif
    @ObservationIgnored var authSession: FuminiwaSession?
    #if FUMINIWA_TEST_COMPOSITION
    @ObservationIgnored var documentOperationDidEnqueue: (@MainActor () -> Void)?
    @ObservationIgnored lazy var documentOperationGate = DocumentOperationGate(didEnqueueOperation: { [weak self] in
        self?.documentOperationDidEnqueue?()
    })
    #else
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    #endif
    @ObservationIgnored let snapshotSyncV2DocumentGate: ProductionDocumentGate
    @ObservationIgnored var snapshotSyncV2Application: SyncV2Application?
    @ObservationIgnored var snapshotSyncV2ConfigurationTask: Task<Void, Never>?
    /// A remote-only download is deliberately outside the document gate. The
    /// token is checked by the installer so an old request can never clear or
    /// replace a newer one after a work switch.
    /// Resume/conflict/open adoption projection is also single-owner. Account
    /// changes cancel the task and invalidate its token before a stale result
    /// can update the editor or account-scoped shelf.
    /// Prevents a new account-scoped operation from starting in the interval
    /// after sign-in/out invalidates existing tokens but before authSession
    /// publishes the replacement account/fence.
    /// Reserves the auth action while the current editor is still allowed to
    /// commit IME text and flush its local checkpoint. The mutation freeze is
    /// raised only after that document boundary succeeds.
    /// The request owner remains stable across the Apple exchange and the
    /// durable scope transition. A late/nested auth action must not release a
    /// newer request's remote-scheduling lease.
    /// Revoke is deliberately not part of the local account transition.  It
    /// may remain suspended on an offline device, while the local shelf and
    /// editor continue to work.  The task is resumed from the vault on the
    /// next launch (and is never allowed to gate document operations).
    @ObservationIgnored lazy var accountTransitionCoordinator = AccountTransitionCoordinator(host: self)
    var authRevokeRetryTask: Task<Void, Never>? {
        accountTransitionCoordinator.revokeTask
    }

    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var hasCompletedBootstrap = false
    @ObservationIgnored var pendingExportRootURL: URL?
    /// Attachment bytes are owned by the Snapshot Sync v2 SQLite/CAS record.
    @ObservationIgnored var workspaceAttachments = WorkspaceAttachmentSet()
    /// Opaque portable-package remainder retained by the shared SQLite v2
    /// store. It is only populated by explicit import/open and is never read
    /// from a package during ordinary document lifecycle operations.
    @ObservationIgnored var syncV2PortableResources: [PortableResource] = []
    /// Exact fractional `createdAt` from the portable manifest.  The
    /// Snapshot v2 `documentCreatedAt` remains the UTC whole-second wire
    /// anchor; this value is only used by the explicit package export path.
    @ObservationIgnored var syncV2PortableCreatedAt: Date?
    @ObservationIgnored var verifiedPrivateDocumentIDs: Set<IOSPrivateDocumentID> = []
    @ObservationIgnored var libraryRefreshGeneration: UInt64 = 0
    @ObservationIgnored var remoteCatalogRefreshGeneration: UInt64 = 0
    @ObservationIgnored var historyRefreshGeneration: UInt64 = 0

    #if FUMINIWA_TEST_COMPOSITION
    @ObservationIgnored var workspaceCheckpointOverride: (@MainActor (WorkspaceCheckpointRequest) async throws -> SyncV2OperationResult)?
    #endif

    @ObservationIgnored
    lazy var saveCoordinator: V2DocumentSaveCoordinator = .init(
        timing: timing,
        currentDocument: { [weak self] in
            guard let self, startupState == .ready else { return nil }
            return document
        },
        saveOperation: { [weak self] document in
            guard let self else { throw CancellationError() }
            try await performCoordinatedDocumentSave(document)
        },
        saveEventHandler: WorkspaceSaveEventProjection.handler(host: self) { [weak self] event in
            switch event {
            case .dirty: self?.saveState = .dirty
            case .saving: self?.saveState = .saving
            case .saved: self?.saveState = .saved
            case .failed: self?.saveState = .failed
            }
        }
    )

    init(
        portableBridge: SyncV2PortableBridge = SyncV2PortableBridge(),
        fileManager: FileManager = .default,
        userDefaults: UserDefaults,
        editorCommandSession: EditorCommandSession = EditorCommandSession(),
        clipboardWriter: any IOSPlainTextClipboardWriting = IOSSystemPlainTextClipboardWriter(),
        backgroundTaskController: any IOSBackgroundTaskControlling = IOSApplicationBackgroundTaskController(),
        privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation? = nil,
        libraryRoot: URL? = nil,
        runtimeComposition: IOSRuntimeComposition = .currentBuild()
    ) {
        let timing = FuminiwaTiming(defaults: userDefaults)
        self.timing = timing
        writingSyncScheduler = WritingSyncScheduler(timing: timing)
        writingProgress = WritingProgressTracker(defaults: userDefaults, timing: timing)
        self.portableBridge = portableBridge
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.editorCommandSession = editorCommandSession
        self.clipboardWriter = clipboardWriter
        self.backgroundTaskController = backgroundTaskController
        self.runtimeComposition = runtimeComposition
        let auth = IOSDocumentStoreComposition.makeAuth(userDefaults: userDefaults)
        browserAuthorization = auth.browserAuthorization
        authSessionVault = auth.sessionVault
        authSessionCoordinator = auth.sessionCoordinator
        appleSignInCoordinator = auth.appleSignInCoordinator
        appleAuthenticationOrchestrator = auth.appleAuthenticationOrchestrator
        authUIState = auth.uiState
        let workingCopy = IOSDocumentStoreComposition.makeWorkingCopy(
            runtimeComposition: runtimeComposition,
            privateWorkingCopyLocation: privateWorkingCopyLocation,
            libraryRoot: libraryRoot,
            fileManager: fileManager
        )
        self.privateWorkingCopyLocation = workingCopy.location
        self.libraryRoot = workingCopy.root
        snapshotSyncV2DocumentGate = SnapshotSyncV2Runtime.makeProductionDocumentGate()
        let placeholder = NovelDocument.newDocument()
        document = placeholder
        documentCreatedAt = Date()
        // URL is retained only for the explicit package import/export bridge.
        // A normal v2 work has no filesystem identity; WorkID + SQLite is the
        // sole durable identity and no per-work directory is created here.
        documentURL = workingCopy.root.standardizedFileURL
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        if workingCopy.location == nil {
            failStartupForDeviceSyncSafety()
        }
    }
}
