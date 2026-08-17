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

@MainActor
@Observable
final class IOSDocumentStore {
    static let lastDocumentNameKey = "FUMINIWAIOS.lastDocumentName"
    /// v2 reopens by WorkID.  The legacy package-recent key remains available
    /// for explicit import/export compatibility, but is never the v2 identity.
    static let lastWorkIDKey = "FUMINIWAIOS.lastWorkID"
    private static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000
    /// Test stores created with the same injected root share one isolated
    /// SQLite composition, so reopen tests exercise persistence rather than a
    /// second unrelated UUID database. Production never consults this cache.
    static var testRuntimeApplications: [URL: SyncV2Application] = [:]
    /// Keep the test composition's UUID-backed SQLite root alongside the
    /// application cache. Removing an application for a restart fixture must
    /// recreate the composition from the same TestRuntimeConfiguration;
    /// constructing a fresh configuration would silently point at a new
    /// database even when the iOS library root is unchanged.
    static var testRuntimeConfigurations: [URL: TestRuntimeConfiguration] = [:]

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
    private(set) var documentSessionGeneration: UInt64 = 0
    private(set) var editorContentGeneration: UInt64 = 0
    private(set) var localEditGeneration: UInt64 = 0
    var isImporterPresented = false
    var pendingExportURL: URL?
    var promptCopyNotice: IOSPromptCopyNotice?
    var operationErrorMessage: String?
    private(set) var attachments: [Attachment] = []
    var libraryItems: [IOSDocumentLibraryItem] = []
    private(set) var deviceSyncStartupFailedSafely = false
    var snapshotSyncOutcome: IOSSnapshotSyncOutcome = .notStarted
    var snapshotSyncConflict: SyncV2ConflictProjection?
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

    let editorCommandSession: EditorCommandSession
    /// The only package boundary owned by the iOS app. Normal document
    /// lifecycle and attachment editing never receive a package repository;
    /// this bridge is called only by explicit import/export actions.
    @ObservationIgnored let portableBridge: SyncV2PortableBridge
    @ObservationIgnored let fileManager: FileManager
    @ObservationIgnored let userDefaults: UserDefaults
    @ObservationIgnored let libraryRoot: URL
    @ObservationIgnored let privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation?
    @ObservationIgnored let backgroundTaskController: any IOSBackgroundTaskControlling
    @ObservationIgnored let clipboardWriter: any IOSPlainTextClipboardWriting
    @ObservationIgnored let authSessionCoordinator: AuthSessionCoordinator?
    @ObservationIgnored let appleSignInCoordinator: AppleSignInCoordinator?
    @ObservationIgnored let appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator?
    @ObservationIgnored var authSession: FuminiwaSession?
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    @ObservationIgnored let snapshotSyncV2DocumentGate: ProductionDocumentGate
    @ObservationIgnored var snapshotSyncV2Application: SyncV2Application?
    @ObservationIgnored var snapshotSyncV2ConfigurationTask: Task<Void, Never>?
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
    @ObservationIgnored var verifiedPrivateDocumentIDs: Set<IOSPrivateDocumentID> = []
    @ObservationIgnored var libraryRefreshGeneration: UInt64 = 0

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
        userDefaults: UserDefaults = .standard,
        editorCommandSession: EditorCommandSession = EditorCommandSession(),
        clipboardWriter: any IOSPlainTextClipboardWriting = IOSSystemPlainTextClipboardWriter(),
        backgroundTaskController: any IOSBackgroundTaskControlling = IOSApplicationBackgroundTaskController(),
        privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation? = nil,
        libraryRoot: URL? = nil
    ) {
        self.portableBridge = portableBridge
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.editorCommandSession = editorCommandSession
        self.clipboardWriter = clipboardWriter
        self.backgroundTaskController = backgroundTaskController
        let environment = FuminiwaRuntimeEnvironment(userDefaults: userDefaults)
        #if canImport(Security)
        let auth: AuthSessionCoordinator? = if environment.allowsNetwork,
                                               let url = environment.syncServerURL,
                                               url.scheme?.lowercased() == "https",
                                               let configuration = try? AuthClientConfiguration(
                                                   origin: url, clientVersion: "0.1.0", clientPlatform: .ios
                                               ),
                                               let transport = try? FuminiwaHTTPAuthTransport(
                                                   configuration: configuration
                                               ),
                                               let limits = try? AuthLimits(
                                                   accessTokenLifetimeSeconds: 900,
                                                   authReceiptLifetimeSeconds: 86400,
                                                   challengeLifetimeSeconds: 300,
                                                   maxCanonicalCommandBytes: 65536,
                                                   maxProviderClockSkewSeconds: 300,
                                                   refreshTokenLifetimeSeconds: 86400
                                               ) {
            AuthSessionCoordinator(
                transport: transport,
                vault: KeychainAuthSessionVault(service: "dev.serikayuzuki.fuminiwa.sync.ios"),
                authLimits: limits,
                platform: .ios
            )
        } else {
            nil
        }
        #else
        let auth: AuthSessionCoordinator? = nil
        #endif
        authSessionCoordinator = auth
        appleSignInCoordinator = AppleSignInCoordinator()
        #if canImport(AuthenticationServices)
        if let auth {
            appleAuthenticationOrchestrator = AppleAuthenticationOrchestrator(
                authSessionCoordinator: auth,
                authorizationProvider: appleSignInCoordinator!,
                credentialStateHandleVault: KeychainAppleCredentialStateHandleVault(),
                credentialStateProvider: SystemAppleCredentialStateProvider()
            )
        } else {
            appleAuthenticationOrchestrator = nil
        }
        #else
        appleAuthenticationOrchestrator = nil
        #endif
        let location: IOSPrivateWorkingCopyLocation? = if let privateWorkingCopyLocation {
            privateWorkingCopyLocation
        } else if let libraryRoot {
            try? IOSPrivateWorkingCopyLocation.prepareInjectedLibraryRoot(libraryRoot, fileManager: fileManager)
        } else {
            try? IOSPrivateWorkingCopyLocation.prepareDefault(fileManager: fileManager)
        }
        self.privateWorkingCopyLocation = location
        let root = location?.rootURL
            ?? libraryRoot?.standardizedFileURL
            ?? Self.defaultLibraryRoot(fileManager: fileManager)
        self.libraryRoot = root
        snapshotSyncV2DocumentGate = SnapshotSyncV2Runtime.makeProductionDocumentGate()
        authUIState = auth == nil ? .unavailable : .signedOut
        let placeholder = NovelDocument.newDocument()
        document = placeholder
        documentCreatedAt = Date()
        // URL is retained only for the explicit package import/export bridge.
        // A normal v2 work has no filesystem identity; WorkID + SQLite is the
        // sole durable identity and no per-work directory is created here.
        documentURL = root.standardizedFileURL
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        if location == nil {
            failStartupForDeviceSyncSafety()
        }
    }

    func failStartupForDeviceSyncSafety() {
        deviceSyncStartupFailedSafely = true
        startupState = .recovery(message: "本文を安全に保存できる場所を確認できませんでした。")
    }

    func markDocumentChanged() {
        guard startupState == .ready,
              !isDocumentTransitionInProgress,
              syncV2KeepBothPendingWorkID == nil else { return }
        localEditGeneration &+= 1
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    func replaceAttachments(_ value: [Attachment]) {
        attachments = value
    }

    func advanceDocumentSessionGeneration() {
        documentSessionGeneration &+= 1
    }

    func advanceEditorContentGeneration() {
        editorContentGeneration &+= 1
    }

    var currentPrivateDocumentID: IOSPrivateDocumentID? {
        guard startupState == .ready,
              snapshotSyncV2Application != nil,
              let workID = syncV2ActiveWorkID else { return nil }
        return IOSPrivateDocumentID(workID: workID)
    }

    var currentDocumentSessionToken: IOSDocumentSessionToken? {
        guard let id = currentPrivateDocumentID else { return nil }
        return IOSDocumentSessionToken(workingCopyID: id, generation: documentSessionGeneration)
    }

    var currentEpisodeEditingToken: IOSEpisodeEditingToken? {
        guard let session = currentDocumentSessionToken, let chapterID = selectedChapterID,
              let episodeID = selectedEpisodeID else { return nil }
        return IOSEpisodeEditingToken(
            documentSession: session, chapterID: chapterID, episodeID: episodeID,
            editorContentGeneration: editorContentGeneration
        )
    }
}
