import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelCore
import NovelStorage
import NovelSyncV2
import NovelSyncV2Application
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
    private static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000

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

    let editorCommandSession: EditorCommandSession
    @ObservationIgnored let repository: any DocumentCopyingRepository
    @ObservationIgnored let attachmentManager: (any AttachmentManaging)?
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
    @ObservationIgnored var verifiedPrivateDocumentIDs: Set<IOSPrivateDocumentID> = []
    @ObservationIgnored var libraryRefreshGeneration: UInt64 = 0

    @ObservationIgnored
    lazy var saveCoordinator: DocumentSaveCoordinator = .init(
        debounceNanoseconds: Self.autosaveDebounceNanoseconds,
        currentState: { [weak self] in
            guard let self, startupState == .ready else { return nil }
            return (document, documentURL)
        },
        saveOperation: { [weak self] document, url in
            guard let self else { throw CancellationError() }
            try await performCoordinatedDocumentSave(document, to: url)
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
        repository: any DocumentCopyingRepository = NovelpkgRepository(),
        attachmentManager: (any AttachmentManaging)? = nil,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        editorCommandSession: EditorCommandSession = EditorCommandSession(),
        clipboardWriter: any IOSPlainTextClipboardWriting = IOSSystemPlainTextClipboardWriter(),
        backgroundTaskController: any IOSBackgroundTaskControlling = IOSApplicationBackgroundTaskController(),
        privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation? = nil,
        libraryRoot: URL? = nil
    ) {
        self.repository = repository
        self.attachmentManager = attachmentManager ?? repository as? any AttachmentManaging
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
                                               let transport = try? FuminiwaHTTPAuthTransport(configuration: configuration),
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
        let root = location?.rootURL ?? libraryRoot?.standardizedFileURL ?? Self.defaultLibraryRoot(fileManager: fileManager)
        self.libraryRoot = root
        snapshotSyncV2DocumentGate = SnapshotSyncV2Runtime.makeProductionDocumentGate()
        authUIState = auth == nil ? .unavailable : .signedOut
        let placeholder = NovelDocument.newDocument()
        document = placeholder
        documentCreatedAt = Date()
        documentURL = root.appendingPathComponent(placeholder.id.uuidString, isDirectory: true)
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
        guard startupState == .ready, !isDocumentTransitionInProgress else { return }
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
        guard startupState == .ready else { return nil }
        if snapshotSyncV2Application != nil {
            return IOSPrivateDocumentID(workID: WorkID(document.id))
        }
        return IOSPrivateDocumentID(packageName: documentURL.lastPathComponent)
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
