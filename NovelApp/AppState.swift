import AppKit
import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelCore
import NovelLocalStore
import NovelSync
import Observation

enum DocumentSaveState: Equatable {
    case unsaved
    case saving
    case saved
    case failed

    var label: String {
        switch self {
        case .unsaved:
            "未保存"
        case .saving:
            "保存中"
        case .saved:
            "保存済み"
        case .failed:
            "保存に失敗しました"
        }
    }

    var systemImage: String {
        switch self {
        case .unsaved:
            "circle.fill"
        case .saving:
            "arrow.triangle.2.circlepath"
        case .saved:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        }
    }
}

enum AuthUIState: Equatable {
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

/// 「別名で保存」の利用者向け結果。保存状態や現在sessionを後から推測せず、
/// URL切替を確定した同じライフサイクル操作から事実を返す。
enum SaveDocumentAsResult: Equatable {
    case saved
    case staleSession
    case failedBeforeSwitch
    case switchedButLatestEditsFailed
}

/// AppStateのactor分離に依存せず、破棄時に通知登録を解除するtoken holder。
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

struct PendingPrivateLibraryPublication {
    let workID: SyncWorkID
    let document: NovelDocument
    let packageURL: URL
    let mayAttemptInitialPublish: Bool
}

/// アプリ全体の状態を管理する(docs/DESIGN.md 5.2)。
///
/// 責務:
/// - 現在開いている作品(`document`)と選択中の章／話IDの保持
/// - 選択中話の取得・本文更新(ロジック自体は `NovelDocument` のヘルパーに委譲し、
///   `AppState` は薄く保つ)
/// - 保存先 URL の保持と、「最近開いた作品」のファイルパスの記録(D-009。
///   App Sandbox 非採用のためセキュリティスコープ付きブックマークは不要 → D-011)
/// - 自動保存: 本文変更は2秒デバウンス、話切り替え時とアプリ非アクティブ時は即保存
///   (docs/DESIGN.md 6.4)
@MainActor
@Observable
final class AppState {
    /// 現在開いている作品。
    var document: NovelDocument
    /// 選択中の章ID。`Chapter` そのものではなく ID で管理する(docs/DESIGN.md 5.2)。
    var selectedChapterID: ChapterID?
    /// 選択中の話ID。本文編集の選択キーは話単位で管理する(D-028)。
    var selectedEpisodeID: EpisodeID?
    /// 選択中の登場人物ID。
    var selectedCharacterID: CharacterID?
    /// 選択中のプロットカードID。
    var selectedPlotCardID: PlotCardID?
    /// 選択中の伏線ID。
    var selectedFlagID: FlagID?
    /// 選択中の世界観ノートID。
    var selectedWorldNoteID: WorldNoteID?
    /// プロット画面 content 列の選択。未割り当てと章を切り替える(UIFIX 4.2)。
    var plotOutlineSelection: PlotOutlineSelection = .unassigned
    /// 原稿パッケージの保存状態。表示はこの値だけを正とする。
    var saveState: DocumentSaveState
    /// 起動中の編集可能placeholderをUIへ露出しないための三状態(D-039)。
    var startupState: AppStartupState
    /// account identityを確認できた時だけnew/importをcloud workとして開始する。
    var permitsCloudLibraryMutation = false
    /// 直近の作品棚connection。作品棚のサーバー操作状態を保持する。
    var lastStartupLibraryConnection: StartupLibraryConnection = .offline
    /// 現在作品がこのaccountへbind済みなら明示保存は出さない。
    var isCurrentWorkBoundToCloud = false
    /// FUMINIWA発行セッション。Appleのcredentialやtokenはここへ保持せず、
    /// AuthSessionCoordinatorのKeychain vaultだけが永続化する。
    var authSession: FuminiwaSession?
    var authUIState: AuthUIState
    var lastSnapshotSyncOutcome: SnapshotSyncOutcome = .notStarted
    var isSnapshotSyncInFlight = false
    /// production syncのlocal metadataを確立できなかったprocessは、
    /// Finder Openや新規作成でruntime-nil writerへ復帰させない。
    var deviceSyncStartupFailedSafely = false
    /// Finderからの作品オープンに失敗したときだけ使う安全な利用者向け文言。
    var externalDocumentOpenErrorMessage: String?
    /// 作品棚の明示操作（サーバーへ保存／複製／削除）のpath-free結果。
    var cloudLibraryActionMessage: String?
    /// clipboardへ送った本文を保持せず、直近のcopy結果だけを表示する一時通知。
    var aiClipboardPromptCopyNotice: AIClipboardPromptCopyNotice?

    /// Project Sidebar と Outline の選択状態。UI2 以降の画面選択の正。
    var workspaceSelection: WorkspaceSelection {
        didSet {
            userDefaults.set(workspaceSelection.section.rawValue, forKey: Self.projectSectionKey)
        }
    }

    /// Outline の検索バーなど、表示専用の一時状態。
    var outlinePresentation = OutlinePresentationState()
    /// 現在の作品に取り込まれている資料一覧。
    var attachments: [Attachment]
    /// 現在の保存先 URL(`.novelpkg` パッケージ)。
    var documentURL: URL
    /// 非同期UI操作が、呼び出し元と同じ作品を対象にしているか確認する世代値。
    var documentSessionToken: DocumentSessionToken
    /// EditorViewへ本文を再流込する世代。作品install/復元時だけ進め、
    /// 同じ本文を保つ別名保存ではcaretとUndoを維持する。
    var editorContentGeneration: UInt64
    /// 選択中話のDevice Sync表示と本文編集権限。
    var deviceSyncState: DeviceSyncUIState
    var deviceSyncTransferState: DeviceSyncTransferState
    var deviceSyncLocalDurabilityState: DeviceSyncLocalDurabilityState
    /// 前回processの本文WALを確認するまでだけEditor入力を止める。
    /// remote account/lease/network待ちには使わない。
    var deviceSyncLocalRecoveryPending = false
    var deviceSyncLocalRecoveryReview: DeviceSyncLocalRecoveryReview?
    @ObservationIgnored var deviceSyncLocalRecoveryChoicePending = false
    var deviceSyncConflict: EpisodeConflict?
    var deviceSyncSetupState: DeviceSyncSetupState = .idle
    /// D-061作品同期の競合。本文Editorへremoteを注入せず、明示sheetでだけ選ばせる。
    var workSyncConflictReview: WorkConflictReview?
    var workSyncLocalRecoveryReview: WorkLocalRecoveryReview?
    var isApplyingWorkSyncConflict = false
    var noteSyncConflict: NoteSyncConflict?

    var hasPendingDeviceSyncReview: Bool {
        noteSyncConflict != nil
            || workSyncConflictReview != nil
            || workSyncLocalRecoveryReview != nil
            || deviceSyncConflict != nil
            || deviceSyncLocalRecoveryReview != nil
    }

    /// The startup Work recovery sheet is owned by ContentView. Keeping it
    /// out of the workbench sheet owner prevents two SwiftUI sheets from
    /// presenting the same legacy review at once.
    var hasWorkbenchDeviceSyncReview: Bool {
        noteSyncConflict != nil
            || workSyncConflictReview != nil
            || deviceSyncConflict != nil
            || deviceSyncLocalRecoveryReview != nil
    }

    let repository: DocumentRepository
    let attachmentManager: AttachmentManaging?
    let userDefaults: UserDefaults
    let fileManager: FileManager
    let defaultDocumentDirectoryName: String
    /// 表示中のEditorKitへ、作品遷移前のIME確定・モデル同期・入力停止を依頼する。
    let editorCommandSession: EditorCommandSession
    /// promptをsystem clipboardへ書く、テスト差し替え可能な境界。
    let clipboardWriter: any PlainTextClipboardWriting
    /// active Editorから確定済み本文だけを読み取る。IME変換中は本文を返さない。
    let activeCommittedTextCapture: @MainActor () -> EditorCommittedTextCaptureResult
    @ObservationIgnored let deviceSyncRuntime: DeviceSyncRuntime?
    /// Post-cutover SQLite canonical store. The legacy package remains the
    /// portable import/export surface; it is no longer the live authority.
    @ObservationIgnored let localCanonicalStore: LocalSQLiteStore?
    @ObservationIgnored let authSessionCoordinator: AuthSessionCoordinator?
    @ObservationIgnored let appleSignInCoordinator: AppleSignInCoordinator?
    @ObservationIgnored let localSnapshotSyncWorker: LocalSnapshotSyncWorker?
    @ObservationIgnored var deviceSyncClients: [DeviceSyncClientKey: DeviceSyncClient] = [:]
    @ObservationIgnored var activeDeviceSyncIdentity: DeviceSyncEpisodeIdentity?
    @ObservationIgnored var resolvedDeviceSyncLookupIdentity: DeviceSyncLookupIdentity?
    @ObservationIgnored var deviceSyncDraftTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncEditIntentTask: Task<Void, Never>?
    @ObservationIgnored var pendingDeviceSyncEditIntentMarker: DeviceSyncEditIntentMarker?
    @ObservationIgnored var deviceSyncEditIntentGeneration: UInt64 = 0
    @ObservationIgnored var deviceSyncMutationSequences: [
        DeviceSyncLocalMutationScope: [SyncContentDigest: DeviceSyncLocalMutation]
    ] = [:]
    @ObservationIgnored var deviceSyncDurablePackageDigests: [EpisodeID: SyncContentDigest] = [:]
    @ObservationIgnored var deviceSyncEditIntentLineage: (
        workingCopyIdentity: String,
        episodeID: EpisodeID,
        contentDigest: SyncContentDigest,
        acceptedPriorPackageDigests: [SyncContentDigest]
    )?
    @ObservationIgnored var deviceSyncSignalTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncPreparationTask: Task<Void, Never>?
    @ObservationIgnored var deviceSyncPreparationLookup: DeviceSyncLookupIdentity?
    @ObservationIgnored var deviceSyncPreparationGeneration: UInt64 = 0
    @ObservationIgnored var pendingDeviceSyncConflictResolution: PendingDeviceSyncConflictResolution?
    @ObservationIgnored var pendingDeviceSyncNewWork: PendingDeviceSyncNewWork?
    @ObservationIgnored var activeWorkSyncIdentity: WorkSyncDocumentIdentity?
    @ObservationIgnored var workSyncClient: WorkSyncClient?
    @ObservationIgnored var noteSyncClient: NoteSyncClient?
    @ObservationIgnored var workSyncPreparationTask: Task<Void, Never>?
    @ObservationIgnored var workSyncPreparationIdentity: WorkSyncPreparationIdentity?
    @ObservationIgnored var workSyncPreparationGeneration: UInt64 = 0
    @ObservationIgnored var workSyncNetworkTask: Task<Void, Never>?
    @ObservationIgnored var workSyncNetworkRescheduleRequested = false
    @ObservationIgnored var workSyncRemoteBindingTask: Task<Void, Never>?
    @ObservationIgnored var pendingLibraryPublishTasks: [SyncWorkID: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingLibraryRetryTask: Task<Void, Never>?
    @ObservationIgnored var mayAttemptInitialCloudPublish = false
    @ObservationIgnored var permitsDeviceSyncSelectionMutationAfterFlush = false
    @ObservationIgnored var permitsDeviceSyncProjectSectionMutationAfterFlush = false
    /// 作品の切替・復元・資料操作など、高レベルの状態遷移を`await`越しに直列化する。
    @ObservationIgnored let documentOperationGate = DocumentOperationGate()
    /// 終了前保存を要求した後に、新しい作品遷移を開始させない。
    @ObservationIgnored var isTerminationPending = false
    /// 重複した終了要求を同じ保存結果へ合流させるsingle-flight Task。
    @ObservationIgnored var terminationTask: Task<Bool, Never>?
    /// copy結果の通知を一定時間後に閉じるTask。prompt本文は捕捉しない。
    @ObservationIgnored var aiClipboardPromptNoticeDismissTask: Task<Void, Never>?
    /// 最終入力確定後から保存・install完了まで、旧UIからのdocument変更を拒否する。
    var isDocumentTransitionInProgress = false
    /// chooserからのopen/new/importを一件だけにし、準備中をUIへ明示する。
    var isStartupLibraryOperationInProgress = false
    /// 章をまたいで戻ったときに復元する、章ごとの最後の話選択。
    @ObservationIgnored
    var lastSelectedEpisodeByChapter: [ChapterID: EpisodeID] = [:]
    @ObservationIgnored var lastAutomaticSnapshotRevision = 0
    @ObservationIgnored var automaticSnapshotTask: Task<Void, Never>?

    /// 保存要求の直列化を担う(D-017)。`document` / `documentURL` の最新値を
    /// クロージャ越しに参照するため、`self` を弱参照で捕捉できるよう `lazy` にする
    /// (`init` の途中で `self` を捕捉すると「全プロパティ初期化前に self を使った」
    /// エラーになるため。`lazy` なら初回アクセス時点で初期化が完了している)。
    /// `@Observable` の観測対象からは外す(UIの再描画とは無関係な内部実装)。
    @ObservationIgnored
    lazy var saveCoordinator: DocumentSaveCoordinator = .init(
        debounceNanoseconds: Self.autosaveDebounceNanoseconds,
        currentState: { [weak self] in
            guard let self, startupState.isReady else { return nil }
            return (document, documentURL)
        },
        saveOperation: { [weak self] doc, url in
            guard let self else { throw CancellationError() }
            try await performCoordinatedDocumentSave(doc, to: url)
        },
        saveEventHandler: { [weak self] event in
            self?.handleSaveEvent(event)
        }
    )

    @ObservationIgnored let resignActiveObserver = NotificationObserverToken()
    /// スリープ直前にIME・package・journalを確定するworkspace通知のtoken。
    @ObservationIgnored let systemSleepObserver = NotificationObserverToken(
        center: NSWorkspace.shared.notificationCenter
    )
    /// pushが欠落してもforeground/wakeでexact fenceを再検査する。
    @ObservationIgnored let becomeActiveObserver = NotificationObserverToken()
    @ObservationIgnored let systemWakeObserver = NotificationObserverToken(
        center: NSWorkspace.shared.notificationCenter
    )
    /// SwiftUIのtask再評価で同時に呼ばれたbootstrapを、同じ完了へ合流させる。
    /// 単なるstartedフラグでは後続呼び出しだけが先にreturnできるため、実行中Taskを保持する。
    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored var hasCompletedBootstrap = false
    /// 初回I/O中に別のtaskが受け取ったFinder URL。初回処理の後に同じTask内で開く。
    @ObservationIgnored var pendingBootstrapOpenURL: URL?
    /// remote-only rowを開くときに、表示したexact head以外を採用しないためのfence。
    @ObservationIgnored var startupRemoteLibraryEntries: [SyncWorkID: SyncWorkLibraryEntry] = [:]
    /// foreground/signal/manual refreshの旧結果が、別accountや新しい棚を上書きしない。
    @ObservationIgnored var startupLibraryRefreshGeneration: UInt64 = 0
    /// remote catalog refreshは同一作品棚のsingle-flightへ合流させる。
    @ObservationIgnored var startupLibraryRefreshTask: Task<Void, Never>?

    static let recentDocumentPathKey = AppPreferenceKey.recentDocumentPath
    static let projectSectionKey = AppPreferenceKey.projectSection
    static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000

    /// D-078 cutover: the SQLite/Rust lane is the live sync authority. The
    /// legacy CloudKit runtime remains available to migration tooling/tests,
    /// but must not participate in the editor lifecycle once this worker is
    /// configured.
    var usesSnapshotSyncRuntime: Bool {
        localSnapshotSyncWorker != nil
    }

    init(
        dependencies: AppDependencies,
        initialStartupState: AppStartupState = .loading
    ) {
        repository = dependencies.repository
        attachmentManager = dependencies.attachmentManager
        userDefaults = dependencies.userDefaults
        fileManager = dependencies.fileManager
        defaultDocumentDirectoryName = dependencies.defaultDocumentDirectoryName
        editorCommandSession = dependencies.editorCommandSession
        clipboardWriter = dependencies.clipboardWriter
        activeCommittedTextCapture = dependencies.activeCommittedTextCapture
        deviceSyncRuntime = dependencies.deviceSyncRuntime
        authSessionCoordinator = dependencies.authSessionCoordinator
        appleSignInCoordinator = dependencies.appleSignInCoordinator
        let localStoreURL = Self.localCanonicalStoreURL(
            fileManager: dependencies.fileManager,
            directoryName: dependencies.defaultDocumentDirectoryName
        )
        localCanonicalStore = try? LocalSQLiteStore(url: localStoreURL)
        if let localCanonicalStore,
           let snapshotSyncTransport = dependencies.snapshotSyncTransport,
           let authSessionCoordinator = dependencies.authSessionCoordinator {
            localSnapshotSyncWorker = LocalSnapshotSyncWorker(
                store: localCanonicalStore,
                transport: snapshotSyncTransport,
                sessionProvider: {
                    try await authSessionCoordinator.currentSession()
                }
            )
        } else {
            localSnapshotSyncWorker = nil
        }
        deviceSyncTransferState = .notApplicable
        deviceSyncLocalDurabilityState = .notApplicable

        // 実際の状態は `bootstrap()` で確立する。ここでは(ウィンドウ表示を
        // ブロックしないよう)空の新規作品をプレースホルダとして持たせておく。
        let placeholder = NovelDocument.newDocument()
        let placeholderURL = Self.defaultSaveURL(
            forTitle: placeholder.title,
            fileManager: dependencies.fileManager,
            directoryName: dependencies.defaultDocumentDirectoryName
        )
        document = placeholder
        documentURL = placeholderURL
        documentSessionToken = DocumentSessionToken(
            generation: 0,
            documentID: placeholder.id,
            documentURL: placeholderURL.standardizedFileURL
        )
        editorContentGeneration = 0
        deviceSyncState = .unconfigured
        deviceSyncConflict = nil
        workSyncConflictReview = nil
        noteSyncConflict = nil
        workSyncLocalRecoveryReview = nil
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        selectedCharacterID = nil
        selectedPlotCardID = nil
        selectedFlagID = nil
        selectedWorldNoteID = nil
        plotOutlineSelection = placeholder.chapters.first.map { .chapter($0.id) } ?? .unassigned
        saveState = .unsaved
        startupState = initialStartupState
        permitsCloudLibraryMutation = deviceSyncRuntime == nil
        authSession = nil
        authUIState = authSessionCoordinator == nil ? .unavailable : .signedOut
        externalDocumentOpenErrorMessage = nil
        aiClipboardPromptCopyNotice = nil
        let storedSection = dependencies.userDefaults.string(forKey: Self.projectSectionKey) ?? ""
        let initialSection: ProjectSection = if storedSection == "planning" {
            .projectInfo
        } else {
            ProjectSection(rawValue: storedSection) ?? .structure
        }
        workspaceSelection = WorkspaceSelection(
            section: initialSection
        )
        if storedSection == "planning" {
            dependencies.userDefaults.set(ProjectSection.projectInfo.rawValue, forKey: Self.projectSectionKey)
        }
        attachments = []
    }

    private static func localCanonicalStoreURL(
        fileManager: FileManager,
        directoryName: String
    ) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("library.sqlite")
    }
}
