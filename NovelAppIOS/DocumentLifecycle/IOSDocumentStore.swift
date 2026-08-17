import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2PortableBridge
import NovelSyncV2Runtime
import Observation

enum IOSStartupState: Equatable { case loading, library, ready, recovery(message: String) }
enum IOSSaveState: Equatable { case saved, dirty, saving, failed }

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

enum IOSAuthUIState: Equatable {
    case unavailable, signedOut, signingIn, signedIn(accountID: String), failed(String)
    var label: String {
        switch self {
        case .unavailable: "アカウント同期は未設定"
        case .signedOut: "未サインイン"
        case .signingIn: "サインイン中…"
        case let .signedIn(accountID): "サインイン済み（\(accountID)）"
        case let .failed(message): message
        }
    }
}

struct IOSEpisodeEditingToken: Hashable, Sendable {
    let documentSession: IOSDocumentSessionToken
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
}

struct IOSEditorContentKey: Hashable {
    let documentSession: IOSDocumentSessionToken
    let episodeID: EpisodeID
    let editorContentGeneration: UInt64
}

struct IOSSnapshotSyncV2ConflictSelection: Equatable, Sendable {
    let workID: WorkID
    let session: IOSDocumentSessionToken
    let editGeneration: UInt64
    let accountScope: IOSSnapshotSyncV2AccountScope
    let conflict: SyncV2ConflictProjection
}

struct IOSSnapshotSyncV2AccountScope: Equatable, Sendable {
    let accountID: String?
    let accountFence: String?
    let serverInstanceID: String?
    let protocolEpoch: Int64?
}

private struct IOSDocumentStoreAuthComposition {
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
            sessionVault: nil,
            sessionCoordinator: nil,
            appleSignInCoordinator: nil,
            appleAuthenticationOrchestrator: nil,
            uiState: .unavailable
        )
        #else
        #if canImport(Security)
        let vault: (any AuthSessionVault)? = KeychainAuthSessionVault(
            service: "dev.serikayuzuki.fuminiwa.sync.ios"
        )
        #else
        let vault: (any AuthSessionVault)? = nil
        #endif
        let auth = makeProductionAuthSession(userDefaults: userDefaults, vault: vault)
        let appleSignIn = AppleSignInCoordinator()
        return IOSDocumentStoreAuthComposition(
            sessionVault: vault,
            sessionCoordinator: auth,
            appleSignInCoordinator: appleSignIn,
            appleAuthenticationOrchestrator: makeProductionAppleOrchestrator(
                auth: auth,
                appleSignIn: appleSignIn
            ),
            uiState: auth == nil ? .unavailable : .signedOut
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

    #if !FUMINIWA_TEST_COMPOSITION
    private static func makeProductionAuthSession(
        userDefaults: UserDefaults,
        vault: (any AuthSessionVault)?
    ) -> AuthSessionCoordinator? {
        let environment = FuminiwaRuntimeEnvironment(userDefaults: userDefaults)
        #if canImport(Security)
        guard environment.allowsNetwork,
              let vault,
              let url = environment.syncServerURL,
              url.scheme?.lowercased() == "https",
              let configuration = try? AuthClientConfiguration(
                  origin: url,
                  clientVersion: "0.1.0",
                  clientPlatform: .ios
              ),
              let transport = try? FuminiwaHTTPAuthTransport(configuration: configuration),
              let limits = try? AuthLimits(
                  accessTokenLifetimeSeconds: 900,
                  authReceiptLifetimeSeconds: 86400,
                  challengeLifetimeSeconds: 300,
                  maxCanonicalCommandBytes: 65536,
                  maxProviderClockSkewSeconds: 300,
                  refreshTokenLifetimeSeconds: 86400
              ) else { return nil }
        return AuthSessionCoordinator(
            transport: transport,
            vault: vault,
            authLimits: limits,
            platform: .ios
        )
        #else
        return nil
        #endif
    }

    private static func makeProductionAppleOrchestrator(
        auth: AuthSessionCoordinator?,
        appleSignIn: AppleSignInCoordinator
    ) -> AppleAuthenticationOrchestrator? {
        #if canImport(AuthenticationServices)
        guard let auth else { return nil }
        return AppleAuthenticationOrchestrator(
            authSessionCoordinator: auth,
            authorizationProvider: appleSignIn,
            credentialStateHandleVault: KeychainAppleCredentialStateHandleVault(),
            credentialStateProvider: SystemAppleCredentialStateProvider()
        )
        #else
        return nil
        #endif
    }
    #endif
}

@MainActor
@Observable
final class IOSDocumentStore {
    static let lastDocumentNameKey = "FUMINIWAIOS.lastDocumentName"
    /// v2 reopens by WorkID.  The legacy package-recent key remains available
    /// for explicit import/export compatibility, but is never the v2 identity.
    static let lastWorkIDKey = "FUMINIWAIOS.lastWorkID"
    private static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000
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

    var document: NovelDocument
    var documentCreatedAt: Date
    var documentURL: URL
    var selectedChapterID: ChapterID?
    var selectedEpisodeID: EpisodeID?
    var startupState: IOSStartupState = .loading
    var saveState: IOSSaveState = .saved
    var authUIState: IOSAuthUIState = .unavailable
    var isDocumentTransitionInProgress = false
    var isNavigationDepartureInProgress = false
    var documentSessionGeneration: UInt64 = 0
    var editorContentGeneration: UInt64 = 0
    var localEditGeneration: UInt64 = 0
    var isImporterPresented = false
    var pendingExportURL: URL?
    var promptCopyNotice: IOSPromptCopyNotice?
    var operationErrorMessage: String?
    var attachments: [Attachment] = []
    var libraryItems: [IOSDocumentLibraryItem] = []
    var deviceSyncStartupFailedSafely = false
    var snapshotSyncOutcome: IOSSnapshotSyncOutcome = .notStarted
    var snapshotSyncConflict: SyncV2ConflictProjection?
    /// Set only after a remote-only document has passed the install boundary.
    /// The shelf uses it to navigate after the asynchronous fetch completes.
    var snapshotSyncV2RemoteOnlyReadyWorkID: WorkID?
    var isSnapshotSyncInFlight = false
    var snapshotSyncState: SyncUIState?
    var syncV2LibraryItems: [SyncV2LibraryItem] = []
    var syncV2RemoteCatalogItems: [SyncV2RemoteCatalogEntry] = []
    var syncV2RemoteCatalogCursor: String?
    var syncV2RemoteCatalogIsLoading = false
    var syncV2RemoteCatalogError: String?
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

    var snapshotSyncV2AccountScope: IOSSnapshotSyncV2AccountScope {
        let serverInstanceID: String?
        #if FUMINIWA_TEST_COMPOSITION
        serverInstanceID = testServerInstanceIDOverride
            ?? authSession?.serverInstanceID.uuidString.lowercased()
        #else
        serverInstanceID = authSession?.serverInstanceID.uuidString.lowercased()
        #endif
        return IOSSnapshotSyncV2AccountScope(
            accountID: authSession?.accountID,
            accountFence: authSession?.accountFence,
            serverInstanceID: serverInstanceID,
            protocolEpoch: authSession.flatMap { Int64(exactly: $0.syncProtocolEpoch) }
        )
    }

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
    @ObservationIgnored let authSessionVault: (any AuthSessionVault)?
    @ObservationIgnored let authSessionCoordinator: AuthSessionCoordinator?
    @ObservationIgnored let appleSignInCoordinator: AppleSignInCoordinator?
    @ObservationIgnored let appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator?
    #if FUMINIWA_TEST_COMPOSITION
    /// App-hosted tests use the production sign-in entry point with a
    /// suspended exchange.  The seam is test-composition-only and is not
    /// present in the shipped iOS target.
    @ObservationIgnored var testAppleSignInHandler: (@MainActor () async throws -> FuminiwaSession)?
    /// The test runtime's scope resolver uses a fixed server namespace. This
    /// override keeps the adapter test aligned with that isolated runtime;
    /// production always uses the session's attested UUID.
    @ObservationIgnored var testServerInstanceIDOverride: String?
    #endif
    @ObservationIgnored var authSession: FuminiwaSession?
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    @ObservationIgnored let snapshotSyncV2DocumentGate: ProductionDocumentGate
    @ObservationIgnored var snapshotSyncV2Application: SyncV2Application?
    @ObservationIgnored var snapshotSyncV2ConfigurationTask: Task<Void, Never>?
    /// A remote-only download is deliberately outside the document gate. The
    /// token is checked by the installer so an old request can never clear or
    /// replace a newer one after a work switch.
    @ObservationIgnored var snapshotSyncV2RemoteOnlyOpenTask: Task<Void, Never>?
    @ObservationIgnored var snapshotSyncV2RemoteOnlyOpenToken: UUID?
    /// Resume/conflict/open adoption projection is also single-owner. Account
    /// changes cancel the task and invalidate its token before a stale result
    /// can update the editor or account-scoped shelf.
    @ObservationIgnored var snapshotSyncV2ReprojectionTask: Task<Void, Never>?
    @ObservationIgnored var snapshotSyncV2ReprojectionToken: UUID?
    /// Prevents a new account-scoped operation from starting in the interval
    /// after sign-in/out invalidates existing tokens but before authSession
    /// publishes the replacement account/fence.
    @ObservationIgnored var syncV2AccountTransitionInProgress = false
    /// Reserves the auth action while the current editor is still allowed to
    /// commit IME text and flush its local checkpoint. The mutation freeze is
    /// raised only after that document boundary succeeds.
    @ObservationIgnored var syncV2AccountTransitionRequested = false
    /// The request owner remains stable across the Apple exchange and the
    /// durable scope transition. A late/nested auth action must not release a
    /// newer request's remote-scheduling lease.
    @ObservationIgnored var syncV2AccountTransitionRequestOwner: UUID?
    @ObservationIgnored var syncV2RemoteSuspensionToken:
        SyncV2AccountTransitionRemoteSuspensionToken?
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var hasCompletedBootstrap = false
    @ObservationIgnored var pendingExportRootURL: URL?
    /// Attachment bytes are owned by the Snapshot Sync v2 SQLite/CAS record.
    @ObservationIgnored var syncV2AttachmentPayloads: [String: Data] = [:]
    @ObservationIgnored var syncV2AttachmentIDs: [String: UUID] = [:]
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
    @ObservationIgnored var historyRefreshGeneration: UInt64 = 0

    @ObservationIgnored
    lazy var saveCoordinator: V2DocumentSaveCoordinator = .init(
        debounceNanoseconds: Self.autosaveDebounceNanoseconds,
        currentDocument: { [weak self] in
            guard let self, startupState == .ready else { return nil }
            return document
        },
        saveOperation: { [weak self] document in
            guard let self else { throw CancellationError() }
            try await performCoordinatedDocumentSave(document)
        },
        saveEventHandler: { [weak self] event in
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
        self.portableBridge = portableBridge
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.editorCommandSession = editorCommandSession
        self.clipboardWriter = clipboardWriter
        self.backgroundTaskController = backgroundTaskController
        self.runtimeComposition = runtimeComposition
        let auth = IOSDocumentStoreComposition.makeAuth(userDefaults: userDefaults)
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
