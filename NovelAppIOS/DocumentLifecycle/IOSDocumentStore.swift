import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelCore
import NovelLocalStore
import NovelStorage
import NovelSync
import Observation

enum IOSStartupState: Equatable {
    case loading
    case library
    case ready
    case recovery(message: String)
}

enum IOSSaveState: Equatable {
    case saved
    case dirty
    case saving
    case failed
}

enum IOSAuthUIState: Equatable {
    case unavailable
    case signedOut
    case signingIn
    case signedIn(accountID: String)
    case failed(String)

    var label: String {
        switch self {
        case .unavailable:
            "アカウント同期は未設定"
        case .signedOut:
            "未サインイン"
        case .signingIn:
            "サインイン中…"
        case let .signedIn(accountID):
            "サインイン済み（\(accountID)）"
        case let .failed(message):
            message
        }
    }
}

/// `UITextView` callbackを、表示時の作品・話・remote install世代へ固定する。
///
/// 同じworking copy・同じEpisodeIDでもremote headのinstall後は
/// `editorContentGeneration`が変わるため、旧surfaceから遅れて届いた本文を拒否できる。
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
    var documentURL: URL
    var selectedChapterID: ChapterID?
    var selectedEpisodeID: EpisodeID?
    var startupState: IOSStartupState = .loading
    var saveState: IOSSaveState = .saved
    var authUIState: IOSAuthUIState = .unavailable
    var snapshotSyncOutcome: SnapshotSyncOutcome = .notStarted
    var snapshotSyncConflict: SnapshotSyncConflict?
    var isSnapshotSyncInFlight = false
    var isDocumentTransitionInProgress = false
    /// 執筆画面から一覧へ戻る間は、端末保存を待つが全画面の準備表示は出さない。
    /// NavigationStackの戻る操作自体は保存完了まで保留して安全性を維持する。
    var isNavigationDepartureInProgress = false
    private(set) var documentSessionGeneration: UInt64 = 0
    private(set) var editorContentGeneration: UInt64 = 0
    var deviceSyncState: IOSDeviceSyncUIState = .unconfigured
    var deviceSyncTransferState: IOSDeviceSyncTransferState = .notApplicable
    var deviceSyncLocalDurabilityState: IOSDeviceSyncLocalDurabilityState = .notApplicable
    /// 前回processの本文WALを確認するまでだけEditor入力を止める。
    /// remote account/lease/network待ちには使わない。
    var deviceSyncLocalRecoveryPending = false
    var deviceSyncLocalRecoveryReview: IOSDeviceSyncLocalRecoveryReview?
    @ObservationIgnored var deviceSyncLocalRecoveryChoicePending = false
    var deviceSyncConflict: EpisodeConflict?
    var workSyncConflictReview: WorkConflictReview?
    var workSyncLocalRecoveryReview: WorkLocalRecoveryReview?
    var workSyncIsApplyingConflict = false
    var noteSyncConflict: NoteSyncConflict?
    var deviceSyncSetupState: IOSDeviceSyncSetupState = .idle
    var libraryItems: [IOSDocumentLibraryItem] = []
    var cloudLibraryItems: [IOSCloudLibraryItem] = []
    var cloudLibraryConnection: IOSCloudLibraryConnection = .offline
    var cloudLibraryIsLoading = false
    private(set) var attachments: [Attachment] = []
    var isImporterPresented = false
    var pendingExportURL: URL?
    var promptCopyNotice: IOSPromptCopyNotice?
    var operationErrorMessage: String?
    private(set) var deviceSyncStartupFailedSafely = false

    func failStartupForDeviceSyncSafety() {
        deviceSyncStartupFailedSafely = true
        startupState = .recovery(
            message: "本文同期の安全情報を確認できないため停止しました。アプリを再起動しても直らない場合は、端末の空き容量とネットワーク設定を確認してください。"
        )
    }

    let editorCommandSession: EditorCommandSession

    @ObservationIgnored let repository: any DocumentCopyingRepository
    @ObservationIgnored let attachmentManager: (any AttachmentManaging)?
    @ObservationIgnored let fileManager: FileManager
    @ObservationIgnored let userDefaults: UserDefaults
    @ObservationIgnored let libraryRoot: URL
    @ObservationIgnored let privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation?
    @ObservationIgnored let backgroundTaskController: any IOSBackgroundTaskControlling
    @ObservationIgnored private let clipboardWriter: any IOSPlainTextClipboardWriting
    @ObservationIgnored let deviceSyncRuntime: IOSDeviceSyncRuntime?
    @ObservationIgnored let authSessionCoordinator: AuthSessionCoordinator?
    @ObservationIgnored let appleSignInCoordinator: AppleSignInCoordinator?
    @ObservationIgnored var authSession: FuminiwaSession?
    @ObservationIgnored var localCanonicalStore: LocalSQLiteStore?
    @ObservationIgnored var localSnapshotSyncWorker: LocalSnapshotSyncWorker?
    @ObservationIgnored var deviceSyncClients: [IOSDeviceSyncClientKey: IOSDeviceSyncClient] = [:]
    @ObservationIgnored var activeDeviceSyncIdentity: IOSDeviceSyncEpisodeIdentity?
    @ObservationIgnored var resolvedDeviceSyncLookupIdentity: IOSDeviceSyncLookupIdentity?
    @ObservationIgnored var deviceSyncDraftTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncEditIntentTask: Task<Void, Never>?
    @ObservationIgnored var pendingDeviceSyncEditIntentMarker: IOSDeviceSyncEditIntentMarker?
    @ObservationIgnored var deviceSyncEditIntentGeneration: UInt64 = 0
    @ObservationIgnored var deviceSyncMutationSequences: [
        IOSDeviceSyncLocalMutationScope: [SyncContentDigest: IOSDeviceSyncLocalMutation]
    ] = [:]
    @ObservationIgnored var deviceSyncDurablePackageDigests: [EpisodeID: SyncContentDigest] = [:]
    @ObservationIgnored var deviceSyncEditIntentLineage: (
        workingCopyIdentity: String,
        episodeID: EpisodeID,
        contentDigest: SyncContentDigest,
        acceptedPriorPackageDigests: [SyncContentDigest]
    )?
    @ObservationIgnored var deviceSyncSignalTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncSignalRefreshTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncSignalRefreshRequested = false
    @ObservationIgnored var deviceSyncPreparationTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncPreparationLookup: IOSDeviceSyncLookupIdentity?
    @ObservationIgnored var deviceSyncPreparationGeneration: UInt64 = 0
    @ObservationIgnored var pendingDeviceSyncConflictResolution: IOSPendingDeviceSyncConflictResolution?
    @ObservationIgnored var workSyncClient: IOSWorkSyncClient?
    @ObservationIgnored var noteSyncClient: IOSNoteSyncClient?
    @ObservationIgnored var activeWorkSyncIdentity: IOSWorkSyncIdentity?
    @ObservationIgnored var workSyncNetworkTask: Task<Void, Never>?
    @ObservationIgnored var workSyncNetworkGeneration: UInt64 = 0
    @ObservationIgnored var workSyncNetworkRescheduleRequested = false
    @ObservationIgnored var workSyncNetworkDemandGeneration: UInt64 = 0
    @ObservationIgnored var workSyncPreparationTask: Task<Void, Never>?
    @ObservationIgnored var workSyncPreparationGeneration: UInt64 = 0
    @ObservationIgnored var pendingDeviceSyncNewWork: IOSPendingDeviceSyncNewWork?
    @ObservationIgnored var permitsDeviceSyncSelectionMutationAfterFlush = false
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var hasCompletedBootstrap = false
    @ObservationIgnored var pendingExportRootURL: URL?
    @ObservationIgnored var verifiedPrivateDocumentIDs: Set<IOSPrivateDocumentID> = []
    @ObservationIgnored var libraryRefreshGeneration: UInt64 = 0
    @ObservationIgnored var cloudLibraryRemoteEntries: [SyncWorkID: SyncWorkLibraryEntry] = [:]
    @ObservationIgnored var activeCloudWorkID: SyncWorkID?
    @ObservationIgnored var permitsCloudLibraryMutation = false
    @ObservationIgnored var mayAttemptInitialCloudPublish = false
    @ObservationIgnored var cloudLibraryOperationInProgress = false
    @ObservationIgnored var pendingCloudLibraryRetryTask: Task<Void, Never>?
    @ObservationIgnored var cloudLibraryRefreshTask: Task<Bool, Never>?
    @ObservationIgnored var lastAutomaticSnapshotRevision = 0
    @ObservationIgnored var automaticSnapshotTask: Task<Void, Never>?

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
            case .dirty:
                self?.saveState = .dirty
                self?.scheduleAutomaticSnapshotAfterEdit()
            case .saving:
                self?.saveState = .saving
            case .saved:
                self?.saveState = .saved
            case .failed:
                self?.saveState = .failed
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
        deviceSyncRuntime: IOSDeviceSyncRuntime? = nil,
        backgroundTaskController: any IOSBackgroundTaskControlling = IOSApplicationBackgroundTaskController(),
        privateWorkingCopyLocation: IOSPrivateWorkingCopyLocation? = nil,
        libraryRoot: URL? = nil
    ) {
        self.repository = repository
        self.attachmentManager = attachmentManager ?? (repository as? any AttachmentManaging)
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.editorCommandSession = editorCommandSession
        self.clipboardWriter = clipboardWriter
        self.deviceSyncRuntime = deviceSyncRuntime
        self.backgroundTaskController = backgroundTaskController

        let runtimeEnvironment = FuminiwaRuntimeEnvironment(userDefaults: userDefaults)
        #if canImport(Security)
        let authSessionCoordinator: AuthSessionCoordinator? = if runtimeEnvironment.allowsNetwork,
                                                                 let syncServerURL = runtimeEnvironment.syncServerURL {
            AuthSessionCoordinator(
                transport: FuminiwaHTTPAuthTransport(baseURL: syncServerURL),
                vault: KeychainAuthSessionVault(service: "dev.serikayuzuki.fuminiwa.sync.ios")
            )
        } else {
            nil
        }
        #else
        let authSessionCoordinator: AuthSessionCoordinator? = nil
        #endif
        self.authSessionCoordinator = authSessionCoordinator
        appleSignInCoordinator = AppleSignInCoordinator()

        let preparedLocation: IOSPrivateWorkingCopyLocation? = if let privateWorkingCopyLocation {
            privateWorkingCopyLocation
        } else if let libraryRoot {
            try? IOSPrivateWorkingCopyLocation.prepareInjectedLibraryRoot(
                libraryRoot,
                fileManager: fileManager
            )
        } else {
            try? IOSPrivateWorkingCopyLocation.prepareDefault(fileManager: fileManager)
        }
        self.privateWorkingCopyLocation = preparedLocation
        let root = preparedLocation?.rootURL
            ?? libraryRoot?.standardizedFileURL
            ?? Self.defaultLibraryRoot(fileManager: fileManager)
        self.libraryRoot = root
        #if canImport(Security)
        authUIState = authSessionCoordinator == nil ? .unavailable : .signedOut
        #else
        authUIState = .unavailable
        #endif
        if preparedLocation == nil {
            // An untrusted injected root must not be used for SQLite either.
            // Keep the store in safe-startup mode without creating anything
            // through a symlink or another rejected path.
            localCanonicalStore = nil
        } else {
            let localStoreURL = root
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("library.sqlite")
            localCanonicalStore = try? LocalSQLiteStore(url: localStoreURL)
        }
        let workerAuthCoordinator: AuthSessionCoordinator? = authSessionCoordinator
        if runtimeEnvironment.allowsNetwork,
           let localCanonicalStore,
           let workerAuthCoordinator,
           let syncServerURL = runtimeEnvironment.syncServerURL {
            localSnapshotSyncWorker = LocalSnapshotSyncWorker(
                store: localCanonicalStore,
                transport: FuminiwaHTTPSnapshotSyncTransport(baseURL: syncServerURL),
                sessionProvider: {
                    try await workerAuthCoordinator.currentSession()
                }
            )
        }
        let placeholder = NovelDocument.newDocument()
        document = placeholder
        documentURL = root.appendingPathComponent("\(placeholder.id.uuidString).novelpkg", isDirectory: true)
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        if preparedLocation == nil {
            failStartupForDeviceSyncSafety()
        }
    }
}

extension IOSDocumentStore {
    func copySelectionPrompt(
        text: String,
        purpose: AIClipboardPromptPurpose,
        expectedEpisodeID: EpisodeID
    ) {
        guard selectedEpisodeID == expectedEpisodeID else {
            showPromptFailure(.staleContext)
            return
        }
        copyPrompt(purpose: purpose, source: .selection(text: text))
    }

    func copyEpisodePrompt(purpose: AIClipboardPromptPurpose, expectedEpisodeID: EpisodeID) {
        guard selectedEpisodeID == expectedEpisodeID else {
            if promptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        guard let episode = synchronizedSelectedEpisodeForPrompt() else {
            if promptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        copyPrompt(purpose: purpose, source: .episode(title: episode.title, content: episode.content))
    }

    func copyChapterPrompt(purpose: AIClipboardPromptPurpose, expectedChapterID: ChapterID) {
        guard selectedChapterID == expectedChapterID else {
            showPromptFailure(.staleContext)
            return
        }
        guard synchronizedSelectedEpisodeForPrompt() != nil else {
            if promptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        guard let chapter = document.chapters.first(where: { $0.id == expectedChapterID }) else {
            if promptCopyNotice == nil {
                showPromptFailure(.staleContext)
            }
            return
        }
        let episodes = chapter.episodes.map {
            AIClipboardPromptEpisode(title: $0.title, content: $0.content)
        }
        copyPrompt(purpose: purpose, source: .chapter(title: chapter.title, episodes: episodes))
    }

    private func synchronizedSelectedEpisodeForPrompt() -> Episode? {
        guard let selectedChapterID, let selectedEpisodeID else { return nil }
        switch editorCommandSession.captureActiveCommittedText() {
        case let .captured(text):
            updateEpisodeContent(text, chapterID: selectedChapterID, episodeID: selectedEpisodeID)
        case .compositionInProgress:
            showPromptFailure(.compositionInProgress)
            return nil
        case .notActive:
            break
        }
        return document.episode(selectedEpisodeID)?.episode
    }

    private func copyPrompt(purpose: AIClipboardPromptPurpose, source: AIClipboardPromptSource) {
        do {
            let prompt = try AIClipboardPromptBuilder.make(purpose: purpose, source: source)
            guard clipboardWriter.writePlainText(prompt.text) else {
                showPromptFailure(.clipboardWriteFailed)
                return
            }
            promptCopyNotice = .success
        } catch let error as AIClipboardPromptError {
            switch error {
            case .emptyContent:
                showPromptFailure(.emptyContent)
            case .sourceCharacterLimitExceeded, .sourceUTF8ByteLimitExceeded, .promptUTF8ByteLimitExceeded:
                showPromptFailure(.contentTooLarge)
            case .encodingFailed:
                showPromptFailure(.promptEncodingFailed)
            }
        } catch {
            showPromptFailure(.promptEncodingFailed)
        }
    }

    private func showPromptFailure(_ failure: IOSPromptCopyFailure) {
        promptCopyNotice = IOSPromptCopyNotice(failure: failure)
    }
}

extension IOSDocumentStore {
    func markDocumentChanged() {
        guard startupState == .ready, !isDocumentTransitionInProgress else { return }
        if usesWholeWorkDeviceSync, activeWorkSyncIdentity != nil {
            deviceSyncTransferState = .localPending
            deviceSyncLocalDurabilityState = .pending
        }
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    func replaceAttachments(_ attachments: [Attachment]) {
        self.attachments = attachments
    }

    func advanceDocumentSessionGeneration() {
        documentSessionGeneration &+= 1
    }

    func advanceEditorContentGeneration() {
        editorContentGeneration &+= 1
    }
}
