import AppKit
import EditorKit
import Foundation
import NovelCore
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

/// 「別名で保存」の利用者向け結果。保存状態や現在sessionを後から推測せず、
/// URL切替を確定した同じライフサイクル操作から事実を返す。
enum SaveDocumentAsResult: Equatable {
    case saved
    case staleSession
    case failedBeforeSwitch
    case switchedButLatestEditsFailed
}

/// AppStateのactor分離に依存せず、破棄時に通知登録を解除するtoken holder。
private final class NotificationObserverToken {
    var value: NSObjectProtocol?

    deinit {
        if let value {
            NotificationCenter.default.removeObserver(value)
        }
    }
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
    private(set) var document: NovelDocument
    /// 選択中の章ID。`Chapter` そのものではなく ID で管理する(docs/DESIGN.md 5.2)。
    private(set) var selectedChapterID: ChapterID?
    /// 選択中の話ID。本文編集の選択キーは話単位で管理する(D-028)。
    private(set) var selectedEpisodeID: EpisodeID?
    /// 選択中の登場人物ID。
    private(set) var selectedCharacterID: CharacterID?
    /// 選択中のプロットカードID。
    private(set) var selectedPlotCardID: PlotCardID?
    /// 選択中の伏線ID。
    private(set) var selectedFlagID: FlagID?
    /// 選択中の世界観ノートID。
    private(set) var selectedWorldNoteID: WorldNoteID?
    /// プロット画面 content 列の選択。未割り当てと章を切り替える(UIFIX 4.2)。
    private(set) var plotOutlineSelection: PlotOutlineSelection = .unassigned
    /// 原稿パッケージの保存状態。表示はこの値だけを正とする。
    private(set) var saveState: DocumentSaveState
    /// 起動中の編集可能placeholderをUIへ露出しないための三状態(D-039)。
    private(set) var startupState: AppStartupState
    /// Finderからの作品オープンに失敗したときだけ使う安全な利用者向け文言。
    var externalDocumentOpenErrorMessage: String?
    /// clipboardへ送った本文を保持せず、直近のcopy結果だけを表示する一時通知。
    private(set) var aiClipboardPromptCopyNotice: AIClipboardPromptCopyNotice?

    /// Project Sidebar と Outline の選択状態。UI2 以降の画面選択の正。
    private(set) var workspaceSelection: WorkspaceSelection {
        didSet {
            userDefaults.set(workspaceSelection.section.rawValue, forKey: Self.projectSectionKey)
        }
    }

    /// Outline の検索バーなど、表示専用の一時状態。
    var outlinePresentation = OutlinePresentationState()
    /// 現在の作品に取り込まれている資料一覧。
    private(set) var attachments: [Attachment]
    /// 現在の保存先 URL(`.novelpkg` パッケージ)。
    private(set) var documentURL: URL
    /// 非同期UI操作が、呼び出し元と同じ作品を対象にしているか確認する世代値。
    private(set) var documentSessionToken: DocumentSessionToken
    /// EditorViewへ本文を再流込する世代。作品install/復元時だけ進め、
    /// 同じ本文を保つ別名保存ではcaretとUndoを維持する。
    private(set) var editorContentGeneration: UInt64

    private let repository: DocumentRepository
    private let attachmentManager: AttachmentManaging?
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let defaultDocumentDirectoryName: String
    /// 表示中のEditorKitへ、作品遷移前のIME確定・モデル同期・入力停止を依頼する。
    private let editorCommandSession: EditorCommandSession
    /// promptをsystem clipboardへ書く、テスト差し替え可能な境界。
    private let clipboardWriter: any PlainTextClipboardWriting
    /// active Editorから確定済み本文だけを読み取る。IME変換中は本文を返さない。
    private let activeCommittedTextCapture: @MainActor () -> EditorCommittedTextCaptureResult
    /// 作品の切替・復元・資料操作など、高レベルの状態遷移を`await`越しに直列化する。
    @ObservationIgnored private let documentOperationGate = DocumentOperationGate()
    /// 終了前保存を要求した後に、新しい作品遷移を開始させない。
    @ObservationIgnored private var isTerminationPending = false
    /// 重複した終了要求を同じ保存結果へ合流させるsingle-flight Task。
    @ObservationIgnored private var terminationTask: Task<Bool, Never>?
    /// copy結果の通知を一定時間後に閉じるTask。prompt本文は捕捉しない。
    @ObservationIgnored private var aiClipboardPromptNoticeDismissTask: Task<Void, Never>?
    /// 最終入力確定後から保存・install完了まで、旧UIからのdocument変更を拒否する。
    private(set) var isDocumentTransitionInProgress = false
    /// 章をまたいで戻ったときに復元する、章ごとの最後の話選択。
    @ObservationIgnored
    private var lastSelectedEpisodeByChapter: [ChapterID: EpisodeID] = [:]

    /// 保存要求の直列化を担う(D-017)。`document` / `documentURL` の最新値を
    /// クロージャ越しに参照するため、`self` を弱参照で捕捉できるよう `lazy` にする
    /// (`init` の途中で `self` を捕捉すると「全プロパティ初期化前に self を使った」
    /// エラーになるため。`lazy` なら初回アクセス時点で初期化が完了している)。
    /// `@Observable` の観測対象からは外す(UIの再描画とは無関係な内部実装)。
    @ObservationIgnored
    private lazy var saveCoordinator: DocumentSaveCoordinator = .init(
        debounceNanoseconds: Self.autosaveDebounceNanoseconds,
        currentState: { [weak self] in
            guard let self, startupState.isReady else { return nil }
            return (document, documentURL)
        },
        saveOperation: { [weak self] doc, url in
            guard let self else { throw CancellationError() }
            do {
                try await repository.save(doc, to: url)
            } catch {
                // 保存失敗でアプリを落とさない。まずはログのみ残し、執筆継続を優先する。
                print("[FUMINIWA] 保存に失敗しました(\(url.path)): \(error)")
                throw error
            }
        },
        saveEventHandler: { [weak self] event in
            self?.handleSaveEvent(event)
        }
    )
    /// holderのdeinitで一度だけ解除するアプリ非アクティブ通知のtoken。
    @ObservationIgnored private let resignActiveObserver = NotificationObserverToken()
    /// SwiftUIのtask再評価で同時に呼ばれたbootstrapを、同じ完了へ合流させる。
    /// 単なるstartedフラグでは後続呼び出しだけが先にreturnできるため、実行中Taskを保持する。
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var hasCompletedBootstrap = false
    /// 初回I/O中に別のtaskが受け取ったFinder URL。初回処理の後に同じTask内で開く。
    @ObservationIgnored private var pendingBootstrapOpenURL: URL?

    private static let recentDocumentPathKey = AppPreferenceKey.recentDocumentPath
    private static let projectSectionKey = AppPreferenceKey.projectSection
    private static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000

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
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        selectedCharacterID = nil
        selectedPlotCardID = nil
        selectedFlagID = nil
        selectedWorldNoteID = nil
        plotOutlineSelection = placeholder.chapters.first.map { .chapter($0.id) } ?? .unassigned
        saveState = .unsaved
        startupState = initialStartupState
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

    /// 起動時の読み込み/新規作成を行う。SwiftUIのtask再評価による同時呼び出しは
    /// 一つの実行と完了へ合流する。
    ///
    /// UserDefaults に前回開いていたファイルパスがあればそれを読み込む。
    /// Finderから指定されたURLはrecentより優先する。読込失敗時は新規作品へ
    /// fallbackせずRecoveryで停止し、原稿とrecent URLを変更しない(D-039)。
    func bootstrap(opening requestedURL: URL? = nil) async {
        if hasCompletedBootstrap {
            if let requestedURL {
                _ = await openExternalDocument(at: requestedURL)
            }
            return
        }

        if let requestedURL {
            pendingBootstrapOpenURL = requestedURL
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let initialOpenURL = pendingBootstrapOpenURL
        pendingBootstrapOpenURL = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performBootstrap(opening: initialOpenURL)
        }
        bootstrapTask = task
        await task.value
    }

    /// 初回状態の確立と、そのI/O中に届いたFinder openを一つの完了境界として処理する。
    /// これにより、どの`bootstrap()`呼び出しもdelegateへ早すぎる完了を返さない。
    private func performBootstrap(opening requestedURL: URL?) async {
        observeResignActive()

        await establishInitialStartupState(opening: requestedURL)

        while let pendingOpenURL = pendingBootstrapOpenURL {
            pendingBootstrapOpenURL = nil
            _ = await openExternalDocument(at: pendingOpenURL)
        }

        hasCompletedBootstrap = true
        bootstrapTask = nil
    }

    private func establishInitialStartupState(opening requestedURL: URL?) async {
        if let requestedURL {
            await loadStartupDocument(at: requestedURL, source: .finder)
            return
        }

        if let path = userDefaults.string(forKey: Self.recentDocumentPathKey), !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            #if DEBUG
            if Self.shouldSkipRecentDocumentInDebug(url, fileManager: fileManager) {
                startupState = .recovery(
                    StartupRecoveryContext(
                        reason: .protectedLocationInDebugBuild,
                        source: .recentDocument,
                        documentURL: url
                    )
                )
                return
            } else {
                await loadStartupDocument(at: url, source: .recentDocument)
                return
            }
            #else
            await loadStartupDocument(at: url, source: .recentDocument)
            return
            #endif
        }

        await createInitialDocumentForStartup()
    }

    /// Recovery画面の「再試行」。同じ原本URLまたは同じ新規保存先を再利用する。
    func retryStartup() async {
        guard !isTerminationPending else { return }
        await documentOperationGate.perform {
            await retryStartupSerially()
        }
    }

    private func retryStartupSerially() async {
        guard case let .recovery(context) = startupState else { return }
        startupState = .loading

        switch context.reason {
        case .cannotOpenDocument, .protectedLocationInDebugBuild:
            guard let url = context.documentURL else {
                startupState = .recovery(context)
                return
            }
            await loadStartupDocument(at: url, source: context.source)
        case .cannotCreateDocument:
            await createInitialDocumentForStartup(at: context.documentURL)
        }
    }

    /// Finder / Open Withから渡された作品を、現在作品を守る通常の切替経路で開く。
    @discardableResult
    func openExternalDocument(at url: URL) async -> Bool {
        let success = await openDocument(at: url)
        if !success, startupState.isReady {
            externalDocumentOpenErrorMessage = "作品を開けませんでした。原稿は切り替えていません。ファイルとアクセス権限を確認してください。"
        }
        return success
    }

    private func loadStartupDocument(at url: URL, source: StartupDocumentSource) async {
        let targetURL = url.standardizedFileURL
        do {
            let loadedDocument = try await repository.load(from: targetURL)
            let loadedAttachments = try await loadAttachmentsThrowing(for: targetURL)
            installDocument(loadedDocument, at: targetURL, attachments: loadedAttachments)
        } catch {
            print("[FUMINIWA] 起動作品を開けませんでした(\(targetURL.lastPathComponent)): \(error)")
            startupState = .recovery(
                StartupRecoveryContext(
                    reason: .cannotOpenDocument,
                    source: source,
                    documentURL: targetURL
                )
            )
        }
    }

    private func createInitialDocumentForStartup(at preferredURL: URL? = nil) async {
        let newDocument = NovelDocument.newDocument()
        let newURL = preferredURL
            ?? Self.availableSaveURL(
                forTitle: newDocument.title,
                fileManager: fileManager,
                directoryName: defaultDocumentDirectoryName
            )

        do {
            try await repository.save(newDocument, to: newURL)
            let newAttachments = try await loadAttachmentsThrowing(for: newURL)
            installDocument(newDocument, at: newURL, attachments: newAttachments)
        } catch {
            print("[FUMINIWA] 起動時の新規作品を保存できませんでした(\(newURL.lastPathComponent)): \(error)")
            startupState = .recovery(
                StartupRecoveryContext(
                    reason: .cannotCreateDocument,
                    source: .initialDocument,
                    documentURL: newURL
                )
            )
        }
    }

    // MARK: - 作品ライフサイクル

    private func performForCurrentDocument<T>(
        expectedSession: DocumentSessionToken? = nil,
        ifStale staleValue: T,
        operation: @MainActor () async -> T
    ) async -> T {
        guard !isTerminationPending else { return staleValue }
        let originSession = expectedSession ?? documentSessionToken
        return await documentOperationGate.perform {
            guard documentSessionToken == originSession else { return staleValue }
            return await operation()
        }
    }

    /// 確認ダイアログなど、`await`を持たないUI操作を元の作品だけへ適用する。
    /// Save Asを含む作品世代の変更後や終了処理開始後は、IDが同じでも拒否する。
    private func permitsMutation(expectedSession: DocumentSessionToken?) -> Bool {
        guard !isTerminationPending, !isDocumentTransitionInProgress else { return false }
        guard let expectedSession else { return true }
        return documentSessionToken == expectedSession
    }

    /// 表示中Editorが確定済み本文をモデルへ同期するための判定。
    ///
    /// 終了要求後は新しいUI操作を止める一方、既に表示中のIME marked textは
    /// 最終保存へ含める必要がある。固定sessionとの一致だけを確認し、終了処理中の
    /// `prepareForDocumentTransition()`から届く最後のcallbackは受け入れる。
    private func permitsEditorSynchronization(expectedSession: DocumentSessionToken?) -> Bool {
        guard !isDocumentTransitionInProgress else { return false }
        guard let expectedSession else { return !isTerminationPending }
        return documentSessionToken == expectedSession
    }

    var permitsDocumentInteraction: Bool {
        startupState.isReady && !isDocumentTransitionInProgress
    }

    var permitsDocumentChoice: Bool {
        startupState.permitsDocumentChoice && !isDocumentTransitionInProgress && !isTerminationPending
    }

    /// provider待機でdocument operation gateを保持せず、開始／再検査時だけ現在作品を読むための条件。
    /// 終了要求後は`permitsDocumentInteraction`がtrueでも新しい長時間処理を開始しない。
    var permitsLongRunningDocumentOperation: Bool {
        startupState.isReady && !isDocumentTransitionInProgress && !isTerminationPending
    }

    /// TextField等のfirst responderとEditorKit本文を同じ同期区間で確定し、
    /// 次の保存・installが終わるまで旧Workbenchからの変更を閉じる。
    private func beginDocumentTransition() -> Bool {
        guard !isDocumentTransitionInProgress else { return false }
        if let keyWindow = NSApp.keyWindow, !keyWindow.makeFirstResponder(nil) {
            return false
        }
        guard editorCommandSession.prepareForDocumentTransition() else { return false }
        isDocumentTransitionInProgress = true
        return true
    }

    private func endDocumentTransition() {
        isDocumentTransitionInProgress = false
        editorCommandSession.resumeAfterDocumentTransition()
    }

    /// 現在の作品を失わず、指定 URL の作品へ切り替える。
    ///
    /// 読み込み結果は一時値に保持し、本文と資料一覧の両方を取得できた後で現在作品の
    /// 保留中保存を完了させる。保存または読み込みに失敗した場合は、現在の状態を
    /// 一切置き換えない。
    @discardableResult
    func openDocument(at url: URL) async -> Bool {
        guard !isTerminationPending else { return false }
        return await documentOperationGate.perform {
            await openDocumentSerially(at: url)
        }
    }

    private func openDocumentSerially(at url: URL) async -> Bool {
        let targetURL = url.standardizedFileURL
        let hadReadyDocument = startupState.isReady
        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }

        guard !hadReadyDocument || targetURL != documentURL.standardizedFileURL else {
            return await saveCoordinator.saveNow()
        }
        if !hadReadyDocument {
            startupState = .loading
        }

        let loadedDocument: NovelDocument
        let loadedAttachments: [Attachment]
        do {
            loadedDocument = try await repository.load(from: targetURL)
            loadedAttachments = try await loadAttachmentsThrowing(for: targetURL)
        } catch {
            print("[FUMINIWA] 作品の読み込みに失敗しました(\(targetURL.lastPathComponent)): \(error)")
            if !hadReadyDocument {
                startupState = .recovery(
                    StartupRecoveryContext(
                        reason: .cannotOpenDocument,
                        source: .chosenDocument,
                        documentURL: targetURL
                    )
                )
            }
            return false
        }

        // 読み込み待ちの間に現在作品が編集されても、ここで全入力を確定・停止し、
        // 最新revisionを保存してから切り替える。
        if hadReadyDocument {
            guard beginDocumentTransition() else { return false }
            didBeginTransition = true
            guard await saveCoordinator.saveNow() else { return false }
        }

        installDocument(loadedDocument, at: targetURL, attachments: loadedAttachments)
        return true
    }

    /// 新規作品を既定保存先へ作成し、保存成功後にだけ現在作品として採用する。
    @discardableResult
    func createNewDocument(expectedSession: DocumentSessionToken? = nil) async -> Bool {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: false) {
            await createNewDocumentSerially()
        }
    }

    private func createNewDocumentSerially() async -> Bool {
        let hadReadyDocument = startupState.isReady
        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }
        let previousRecoveryContext: StartupRecoveryContext? = if case let .recovery(context) = startupState {
            context
        } else {
            nil
        }

        if !hadReadyDocument {
            startupState = .loading
        }

        let newDocument = NovelDocument.newDocument()
        let newURL = Self.availableSaveURL(
            forTitle: newDocument.title,
            fileManager: fileManager,
            directoryName: defaultDocumentDirectoryName
        )
        let newAttachments: [Attachment]

        do {
            try await repository.save(newDocument, to: newURL)
            newAttachments = try await loadAttachmentsThrowing(for: newURL)
        } catch {
            print("[FUMINIWA] 新規作品の保存に失敗しました(\(newURL.lastPathComponent)): \(error)")
            if !hadReadyDocument {
                startupState = .recovery(
                    StartupRecoveryContext(
                        reason: .cannotCreateDocument,
                        source: .initialDocument,
                        documentURL: newURL
                    )
                )
            } else if let previousRecoveryContext {
                startupState = .recovery(previousRecoveryContext)
            }
            return false
        }

        // 新規作品の書き込み中にも現在作品は編集できる。切り替え直前に全入力を
        // 確定・停止し、最新revisionを現在の保存先へ確実に残す。
        if hadReadyDocument {
            guard beginDocumentTransition() else { return false }
            didBeginTransition = true
            guard await saveCoordinator.saveNow() else { return false }
        }

        installDocument(newDocument, at: newURL, attachments: newAttachments)
        return true
    }

    /// 現在作品を別 URL へ複製し、成功後にだけ保存先を切り替える。
    ///
    /// `DocumentCopyingRepository` が利用できる場合は、モデル外の資料・
    /// スナップショット・未知項目も保存層に引き継がせる。コピー中に生じた編集は
    /// dirty revision として残り、保存先切り替え後に新 URL へ保存される。
    @discardableResult
    func saveDocument(as url: URL, expectedSession: DocumentSessionToken? = nil) async -> Bool {
        await saveDocumentResult(as: url, expectedSession: expectedSession) == .saved
    }

    /// Presenterが非同期完了後の可変状態から失敗理由を推測しないための結果付き経路。
    func saveDocumentResult(
        as url: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> SaveDocumentAsResult {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: .staleSession) {
            await saveDocumentSerially(as: url)
        }
    }

    private func saveDocumentSerially(as url: URL) async -> SaveDocumentAsResult {
        guard startupState.isReady else { return .failedBeforeSwitch }
        let destinationURL = url.standardizedFileURL
        let sourceURL = documentURL

        guard destinationURL != sourceURL.standardizedFileURL else {
            return await saveCoordinator.saveNow() ? .saved : .failedBeforeSwitch
        }

        var didBeginTransition = false
        defer {
            if didBeginTransition {
                endDocumentTransition()
            }
        }

        do {
            let result = try await saveCoordinator.performExclusiveAfterFlushing(flushAfter: true) {
                let documentSnapshot = document
                if let copyingRepository = repository as? DocumentCopyingRepository {
                    try await copyingRepository.saveCopy(
                        documentSnapshot,
                        from: sourceURL,
                        to: destinationURL
                    )
                } else {
                    try await repository.save(documentSnapshot, to: destinationURL)
                }

                // copy中も入力は継続できる。保存先を切り替える直前にIMEを旧sessionへ
                // 確定し、Editor keyの更新と事後保存が終わるまで入力を止める。
                guard beginDocumentTransition() else { return false }
                didBeginTransition = true

                // URL・recent・session世代の切替までを保存排他区間に含める。
                // コピー中に待機した通常保存が、旧URLへ再開する隙間を作らない。
                documentURL = destinationURL
                rememberDocumentURL(destinationURL)
                advanceDocumentSession(document: document, url: destinationURL)
                return true
            }

            switch result {
            case .saveFailedBeforeOperation:
                return .failedBeforeSwitch
            case let .completed(didSwitch, savedAfterOperation):
                guard didSwitch else { return .failedBeforeSwitch }
                return savedAfterOperation ? .saved : .switchedButLatestEditsFailed
            }
        } catch {
            print("[FUMINIWA] 別名保存に失敗しました(\(destinationURL.path)): \(error)")
            return .failedBeforeSwitch
        }
    }

    // MARK: - 選択中章

    /// Project Sidebar のセクションを選択する。UI2 では画面の主導線として使う。
    func selectProjectSection(_ section: ProjectSection) {
        guard workspaceSelection.section != section else { return }
        workspaceSelection = WorkspaceSelection(section: section)
        if section == .worldbuilding {
            ensureWorldNoteSelection()
        }
    }

    /// 選択中の章(存在しなければ `nil`)。
    var selectedChapter: Chapter? {
        guard let selectedChapterID else { return nil }
        return document.chapters.first { $0.id == selectedChapterID }
    }

    /// 選択中の話(存在しなければ `nil`)。
    var selectedEpisode: Episode? {
        guard let selectedEpisodeID else { return nil }
        return selectedChapter?.episodes.first { $0.id == selectedEpisodeID }
    }

    /// 本文右クリックで取得したexact selectionから、AIチャット用promptをコピーする。
    ///
    /// context menu表示後に作品や話が変わっていた場合は、同じ文字列が存在しても
    /// 現在選択へ読み替えない。IME変換中も未確定文字を欠いたpromptを作らない。
    @discardableResult
    func copySelectionAIChatPrompt(
        purpose: AIClipboardPromptPurpose,
        selectedText: String,
        episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        let episodeStillExists = document.chapters.first(where: { $0.id == chapterID })?
            .episodes.contains(where: { $0.id == episodeID }) == true
        let isCurrentSelection = isCurrentAIClipboardPromptContext(expectedSession) &&
            workspaceSelection.section == .structure &&
            selectedChapterID == chapterID &&
            selectedEpisodeID == episodeID &&
            episodeStillExists
        guard isCurrentSelection else {
            return failAIClipboardPromptCopy(.staleContext)
        }

        switch activeCommittedTextCapture() {
        case .captured:
            return copyAIClipboardPrompt(
                purpose: purpose,
                source: .selection(text: selectedText)
            )
        case .compositionInProgress:
            return failAIClipboardPromptCopy(.compositionInProgress)
        case .notActive:
            return failAIClipboardPromptCopy(.staleContext)
        }
    }

    /// 指定話のタイトルと本文だけを含むAIチャット用promptをコピーする。
    @discardableResult
    func copyEpisodeAIChatPrompt(
        purpose: AIClipboardPromptPurpose,
        episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        guard isCurrentAIClipboardPromptContext(expectedSession) else {
            return failAIClipboardPromptCopy(.staleContext)
        }
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else {
            return failAIClipboardPromptCopy(.staleContext)
        }
        guard let episode = chapter.episodes.first(where: { $0.id == episodeID }) else {
            return failAIClipboardPromptCopy(.staleContext)
        }

        let content: String
        if workspaceSelection.section == .structure,
           selectedChapterID == chapterID,
           selectedEpisodeID == episodeID
        {
            switch activeCommittedTextCapture() {
            case let .captured(committedText):
                content = committedText
            case .compositionInProgress:
                return failAIClipboardPromptCopy(.compositionInProgress)
            case .notActive:
                content = episode.content
            }
        } else {
            content = episode.content
        }

        return copyAIClipboardPrompt(
            purpose: purpose,
            source: .episode(title: episode.title, content: content)
        )
    }

    /// 指定章のタイトルと、配列順の全話タイトル／本文だけを含むpromptをコピーする。
    @discardableResult
    func copyChapterAIChatPrompt(
        purpose: AIClipboardPromptPurpose,
        chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        guard isCurrentAIClipboardPromptContext(expectedSession) else {
            return failAIClipboardPromptCopy(.staleContext)
        }
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else {
            return failAIClipboardPromptCopy(.staleContext)
        }

        var activeEpisodeContent: (id: EpisodeID, text: String)?
        let selectedEpisodeBelongsToChapter = selectedEpisodeID.map { selectedEpisodeID in
            chapter.episodes.contains(where: { $0.id == selectedEpisodeID })
        } ?? false
        let activeEpisodeID = workspaceSelection.section == .structure &&
            selectedChapterID == chapterID && selectedEpisodeBelongsToChapter
            ? selectedEpisodeID
            : nil
        if let activeEpisodeID {
            switch activeCommittedTextCapture() {
            case let .captured(committedText):
                activeEpisodeContent = (activeEpisodeID, committedText)
            case .compositionInProgress:
                return failAIClipboardPromptCopy(.compositionInProgress)
            case .notActive:
                break
            }
        }

        let episodes = chapter.episodes.map { episode in
            AIClipboardPromptEpisode(
                title: episode.title,
                content: activeEpisodeContent?.id == episode.id
                    ? activeEpisodeContent?.text ?? episode.content
                    : episode.content
            )
        }
        return copyAIClipboardPrompt(
            purpose: purpose,
            source: .chapter(title: chapter.title, episodes: episodes)
        )
    }

    func dismissAIClipboardPromptCopyNotice() {
        aiClipboardPromptNoticeDismissTask?.cancel()
        aiClipboardPromptNoticeDismissTask = nil
        aiClipboardPromptCopyNotice = nil
    }

    private func isCurrentAIClipboardPromptContext(_ expectedSession: DocumentSessionToken) -> Bool {
        permitsLongRunningDocumentOperation && documentSessionToken == expectedSession
    }

    @discardableResult
    private func copyAIClipboardPrompt(
        purpose: AIClipboardPromptPurpose,
        source: AIClipboardPromptSource
    ) -> Bool {
        do {
            let prompt = try AIClipboardPromptBuilder.make(purpose: purpose, source: source)
            guard clipboardWriter.writePlainText(prompt.text) else {
                return failAIClipboardPromptCopy(.clipboardWriteFailed)
            }
            presentAIClipboardPromptCopyNotice(.success)
            return true
        } catch let error as AIClipboardPromptError {
            return failAIClipboardPromptCopy(copyFailure(for: error))
        } catch {
            return failAIClipboardPromptCopy(.promptEncodingFailed)
        }
    }

    private func copyFailure(for error: AIClipboardPromptError) -> AIClipboardPromptCopyFailure {
        switch error {
        case .emptyContent:
            .emptyContent
        case .sourceCharacterLimitExceeded, .sourceUTF8ByteLimitExceeded, .promptUTF8ByteLimitExceeded:
            .contentTooLarge
        case .encodingFailed:
            .promptEncodingFailed
        }
    }

    @discardableResult
    private func failAIClipboardPromptCopy(_ failure: AIClipboardPromptCopyFailure) -> Bool {
        presentAIClipboardPromptCopyNotice(.failure(failure))
        return false
    }

    private func presentAIClipboardPromptCopyNotice(_ outcome: AIClipboardPromptCopyOutcome) {
        aiClipboardPromptNoticeDismissTask?.cancel()
        let notice = AIClipboardPromptCopyNotice(outcome: outcome)
        aiClipboardPromptCopyNotice = notice
        aiClipboardPromptNoticeDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self, aiClipboardPromptCopyNotice?.id == notice.id else { return }
            aiClipboardPromptCopyNotice = nil
            aiClipboardPromptNoticeDismissTask = nil
        }
    }

    /// 選択中の登場人物(存在しなければ `nil`)。
    var selectedCharacter: NovelCore.Character? {
        guard let selectedCharacterID else { return nil }
        return document.characters.first { $0.id == selectedCharacterID }
    }

    /// 選択中のプロットカード(存在しなければ `nil`)。
    var selectedPlotCard: PlotCard? {
        guard let selectedPlotCardID else { return nil }
        return document.plotCards.first { $0.id == selectedPlotCardID }
    }

    /// 選択中の伏線(存在しなければ `nil`)。
    var selectedFlag: Flag? {
        guard let selectedFlagID else { return nil }
        return document.flags.first { $0.id == selectedFlagID }
    }

    /// 選択中の世界観ノート(存在しなければ `nil`)。
    var selectedWorldNote: WorldNote? {
        guard let selectedWorldNoteID else { return nil }
        return document.worldNotes.first { $0.id == selectedWorldNoteID }
    }

    // MARK: - 世界観ノート

    /// 世界観ノートを追加し、追加したノートを選択する。
    func addWorldNote() {
        guard permitsDocumentInteraction else { return }
        let note = WorldNote(title: "")
        document.worldNotes.append(note)
        selectedWorldNoteID = note.id
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 世界観ノートを選択する。選択前の本文はdidChangeでモデルへ反映済みとする。
    func selectWorldNote(_ id: WorldNoteID?) {
        guard permitsDocumentInteraction else { return }
        guard id == nil || document.worldNotes.contains(where: { $0.id == id }) else { return }
        guard selectedWorldNoteID != id else { return }
        selectedWorldNoteID = id
        flushSaveImmediately()
    }

    /// 世界観ノートのタイトルを更新する。空タイトルは編集中の値として許可する。
    func updateWorldNoteTitle(_ title: String, for id: WorldNoteID) {
        guard permitsDocumentInteraction else { return }
        guard let index = document.worldNotes.firstIndex(where: { $0.id == id }),
              document.worldNotes[index].title != title else { return }
        document.worldNotes[index].title = title
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 世界観ノートの本文を更新する。モデル反映は即時、保存だけをデバウンスする。
    func updateWorldNoteContent(
        _ content: String,
        for id: WorldNoteID,
        expectedSession: DocumentSessionToken? = nil
    ) {
        guard permitsEditorSynchronization(expectedSession: expectedSession) else { return }
        guard let index = document.worldNotes.firstIndex(where: { $0.id == id }),
              document.worldNotes[index].content != content else { return }
        document.worldNotes[index].content = content
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 世界観ノートを削除し、隣接ノートへ選択を移す。
    @discardableResult
    func deleteWorldNote(id: WorldNoteID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let index = document.worldNotes.firstIndex(where: { $0.id == id }) else { return false }
        document.worldNotes.remove(at: index)
        if selectedWorldNoteID == id {
            let fallbackIndex = min(index, max(document.worldNotes.count - 1, 0))
            selectedWorldNoteID = document.worldNotes.indices.contains(fallbackIndex)
                ? document.worldNotes[fallbackIndex].id
                : nil
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 世界観ノートの並び順を更新する。
    func moveWorldNotes(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.worldNotes.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    private func ensureWorldNoteSelection() {
        if let selectedWorldNoteID,
           document.worldNotes.contains(where: { $0.id == selectedWorldNoteID })
        {
            return
        }
        selectedWorldNoteID = document.worldNotes.first?.id
    }

    /// 章を選択する。最後に選択していた話、なければ先頭の話も選択する。
    /// 選択が変わるたびに即座に保存する(docs/DESIGN.md 6.4)。
    func selectChapter(_ id: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard id != selectedChapterID else { return }
        setSelection(chapterID: id, episodeID: id.flatMap(preferredEpisodeID(in:)))
        flushSaveImmediately()
    }

    /// プロット画面の章Outline選択を更新する。章を選んだときは執筆側の章選択も揃える。
    func selectPlotOutline(_ selection: PlotOutlineSelection) {
        guard permitsDocumentInteraction else { return }
        guard selection != plotOutlineSelection else { return }
        plotOutlineSelection = selection
        if case let .chapter(chapterID) = selection {
            setSelection(chapterID: chapterID, episodeID: preferredEpisodeID(in: chapterID))
            flushSaveImmediately()
        }
    }

    /// 話を選択する。`chapterID` を省略した場合は現在の章を対象にする。
    func selectEpisode(_ id: EpisodeID?, in chapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        let targetChapterID = chapterID ?? selectedChapterID
        guard let targetChapterID else { return }
        guard let id else {
            guard document.chapters.first(where: { $0.id == targetChapterID })?.episodes.isEmpty == true else { return }
            setSelection(chapterID: targetChapterID, episodeID: nil)
            flushSaveImmediately()
            return
        }
        guard document.chapters.contains(where: { chapter in
            chapter.id == targetChapterID && chapter.episodes.contains(where: { $0.id == id })
        }) else { return }
        setSelection(chapterID: targetChapterID, episodeID: id)
        flushSaveImmediately()
    }

    // MARK: - 章操作(ロジックは NovelDocument 側のヘルパーに委譲)

    /// 章を末尾に追加し、追加した章を選択状態にする。
    func addChapter() {
        guard permitsDocumentInteraction else { return }
        let title = "第\(document.chapters.count + 1)章"
        let newID = document.addChapter(title: title)
        setSelection(chapterID: newID, episodeID: nil)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 指定章に話を追加し、追加した話を選択する。
    ///
    /// `title` を省略したときは、その章内の通し番号で「第N話」を付ける(UIFIX 2.1)。
    func addEpisode(to chapterID: ChapterID? = nil, title: String? = nil) {
        guard permitsDocumentInteraction else { return }
        let targetChapterID = chapterID ?? selectedChapterID
        guard let targetChapterID,
              let chapter = document.chapters.first(where: { $0.id == targetChapterID }) else { return }
        let resolvedTitle = title ?? "第\(chapter.episodes.count + 1)話"
        guard let episodeID = document.addEpisode(to: targetChapterID, title: resolvedTitle) else { return }
        setSelection(chapterID: targetChapterID, episodeID: episodeID)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 選択中話のタイトルを更新する。
    func updateSelectedEpisodeTitle(_ title: String) {
        guard permitsDocumentInteraction else { return }
        guard let selectedEpisodeID, let selectedChapterID else { return }
        guard selectedEpisode?.title != title else { return }
        document.updateEpisodeTitle(title, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 話のタイトルを更新する。
    func updateEpisodeTitle(_ title: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard permitsDocumentInteraction else { return }
        guard document.episode(episodeID)?.episode.title != title else { return }
        document.updateEpisodeTitle(title, for: episodeID, in: chapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 作品タイトルを更新する。空タイトルも編集中は許可し、保存はデバウンスする。
    func updateDocumentTitle(_ title: String) {
        guard permitsDocumentInteraction else { return }
        guard document.title != title else { return }
        document.title = title
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 作品あらすじを更新する。保存形式の詳細はNovelStorageに閉じ込める。
    func updateDocumentSynopsis(_ synopsis: String) {
        guard permitsDocumentInteraction else { return }
        guard document.synopsis != synopsis else { return }
        document.synopsis = synopsis
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 話タイトルの編集を確定し、空タイトルを既定値へ戻す。
    func commitEpisodeTitleEditing() {
        guard permitsDocumentInteraction else { return }
        for chapter in document.chapters {
            for episode in chapter.episodes {
                let normalizedTitle = normalizedEpisodeTitle(episode.title)
                if episode.title != normalizedTitle {
                    document.updateEpisodeTitle(normalizedTitle, for: episode.id, in: chapter.id)
                    saveCoordinator.markDirty()
                }
            }
        }
        flushSaveImmediately()
    }

    /// 章タイトルを更新する。タイトル編集中は頻繁に呼ばれるため保存はデバウンスする。
    func updateChapterTitle(_ title: String, for id: ChapterID) {
        guard permitsDocumentInteraction else { return }
        guard document.chapters.first(where: { $0.id == id })?.title != title else { return }
        document.updateTitle(title, for: id)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// タイトル編集の確定時に、未保存分を即時保存へ寄せる。
    func commitChapterTitleEditing() {
        guard permitsDocumentInteraction else { return }
        for chapter in document.chapters {
            let normalizedTitle = normalizedChapterTitle(chapter.title)
            if chapter.title != normalizedTitle {
                document.updateTitle(normalizedTitle, for: chapter.id)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 章を削除し、隣接章へ選択を移す。最後の1章は削除しない。
    @discardableResult
    func deleteChapter(id: ChapterID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard document.chapters.count > 1 else { return false }
        guard let originalIndex = document.chapters.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removeChapter(id: id) != nil else { return false }

        if selectedChapterID == id {
            let fallbackIndex = min(originalIndex, document.chapters.count - 1)
            let fallbackChapterID = document.chapters.indices.contains(fallbackIndex) ? document.chapters[fallbackIndex].id : nil
            setSelection(chapterID: fallbackChapterID, episodeID: fallbackChapterID.flatMap(preferredEpisodeID(in:)))
        }
        if case let .chapter(focusedID) = plotOutlineSelection, focusedID == id {
            if let selectedChapterID {
                plotOutlineSelection = .chapter(selectedChapterID)
            } else {
                plotOutlineSelection = .unassigned
            }
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 章を並べ替える(`List.onMove` からそのまま呼べる形)。
    func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 話を削除し、同じ章の隣接話へ選択を移す。
    @discardableResult
    func deleteEpisode(
        id episodeID: EpisodeID,
        from chapterID: ChapterID? = nil,
        expectedSession: DocumentSessionToken? = nil
    ) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        let sourceChapterID = chapterID ?? selectedChapterID
        guard let sourceChapterID,
              let originalIndex = document.episode(episodeID)?.chapterID == sourceChapterID
              ? document.chapters.first(where: { $0.id == sourceChapterID })?.episodes.firstIndex(where: { $0.id == episodeID })
              : nil,
              document.removeEpisode(id: episodeID, from: sourceChapterID) != nil else { return false }

        if selectedEpisodeID == episodeID {
            let remaining = document.chapters.first(where: { $0.id == sourceChapterID })?.episodes ?? []
            let fallbackIndex = min(originalIndex, max(remaining.count - 1, 0))
            let fallbackEpisodeID = remaining.indices.contains(fallbackIndex) ? remaining[fallbackIndex].id : nil
            setSelection(chapterID: sourceChapterID, episodeID: fallbackEpisodeID)
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 章内の話を並べ替える。
    func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 話を同じ章内または別章へ移動する。
    @discardableResult
    func moveEpisode(
        id episodeID: EpisodeID,
        from sourceChapterID: ChapterID,
        to destinationChapterID: ChapterID,
        before targetEpisodeID: EpisodeID? = nil
    ) -> Bool {
        guard permitsDocumentInteraction else { return false }
        guard document.moveEpisode(
            id: episodeID,
            from: sourceChapterID,
            to: destinationChapterID,
            before: targetEpisodeID
        ) else { return false }
        if selectedEpisodeID == episodeID {
            setSelection(chapterID: destinationChapterID, episodeID: episodeID)
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 選択中章の本文を更新する。編集のたびに呼ばれる想定で、モデル更新は即座に行い、
    /// ディスクへの保存は2秒デバウンスする(テキスト所有権ルール D-005。
    /// `EditorView` から編集中に本文を書き戻すことはしない)。
    func updateSelectedEpisodeContent(_ content: String) {
        guard let selectedChapterID, let selectedEpisodeID else { return }
        updateEpisodeContent(content, for: selectedEpisodeID, in: selectedChapterID)
    }

    /// 表示時に固定した話・章・作品セッションへ本文を反映する。
    ///
    /// 作品遷移前のIME確定通知が、遷移先の「現在選択」へ流れ込まないよう、
    /// EditorViewのcallbackはこのAPIへ固定IDとsessionを渡す。
    func updateEpisodeContent(
        _ content: String,
        for episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: DocumentSessionToken? = nil
    ) {
        guard permitsEditorSynchronization(expectedSession: expectedSession) else { return }
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }),
              let episode = chapter.episodes.first(where: { $0.id == episodeID }),
              episode.content != content else { return }
        document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中章のメモを更新する。メモは短文想定の補助情報なので SwiftUI 側の
    /// `TextEditor` から通常の Binding 更新で呼ばれる。
    func updateSelectedEpisodeMemo(_ memo: String) {
        guard permitsDocumentInteraction else { return }
        guard let selectedChapterID, let selectedEpisodeID else { return }
        guard selectedEpisode?.memo != memo else { return }
        document.updateEpisodeMemo(memo, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    // MARK: - 登場人物

    /// 登場人物を追加し、追加した人物を選択状態にする。
    func addCharacter() {
        guard permitsDocumentInteraction else { return }
        let newID = document.addCharacter(name: "名無し")
        selectedCharacterID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 登場人物を選択する。
    func selectCharacter(_ id: CharacterID?) {
        guard permitsDocumentInteraction else { return }
        selectedCharacterID = id
    }

    /// 選択中の登場人物を更新する。
    func updateSelectedCharacter(
        name: String? = nil,
        kana: String? = nil,
        memo: String? = nil,
        colorHex: String? = nil,
        role: String? = nil,
        age: String? = nil,
        gender: String? = nil,
        firstPerson: String? = nil,
        secondPerson: String? = nil,
        speechStyle: String? = nil,
        appearance: String? = nil,
        personality: String? = nil,
        background: String? = nil
    ) {
        guard permitsDocumentInteraction else { return }
        guard let selectedCharacterID, let current = selectedCharacter else { return }
        let nextName = name ?? current.name
        let nextKana = kana ?? current.kana
        let nextMemo = memo ?? current.memo
        let nextColorHex = colorHex ?? current.colorHex
        let nextRole = role ?? current.role
        let nextAge = age ?? current.age
        let nextGender = gender ?? current.gender
        let nextFirstPerson = firstPerson ?? current.firstPerson
        let nextSecondPerson = secondPerson ?? current.secondPerson
        let nextSpeechStyle = speechStyle ?? current.speechStyle
        let nextAppearance = appearance ?? current.appearance
        let nextPersonality = personality ?? current.personality
        let nextBackground = background ?? current.background

        guard current.name != nextName || current.kana != nextKana || current.memo != nextMemo ||
            current.colorHex != nextColorHex || current.role != nextRole || current.age != nextAge ||
            current.gender != nextGender || current.firstPerson != nextFirstPerson ||
            current.secondPerson != nextSecondPerson || current.speechStyle != nextSpeechStyle ||
            current.appearance != nextAppearance || current.personality != nextPersonality ||
            current.background != nextBackground else
        {
            return
        }

        document.updateCharacter(
            id: selectedCharacterID,
            name: nextName,
            kana: nextKana,
            memo: nextMemo,
            colorHex: nextColorHex,
            role: nextRole,
            age: nextAge,
            gender: nextGender,
            firstPerson: nextFirstPerson,
            secondPerson: nextSecondPerson,
            speechStyle: nextSpeechStyle,
            appearance: nextAppearance,
            personality: nextPersonality,
            background: nextBackground
        )
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// Optional な登場人物シート項目を更新する。空文字は `nil` として保存する。
    func updateSelectedCharacterProfile(
        role: String? = nil,
        age: String? = nil,
        gender: String? = nil,
        firstPerson: String? = nil,
        secondPerson: String? = nil,
        speechStyle: String? = nil,
        appearance: String? = nil,
        personality: String? = nil,
        background: String? = nil
    ) {
        guard permitsDocumentInteraction else { return }
        updateSelectedCharacter(
            role: role.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.role,
            age: age.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.age,
            gender: gender.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.gender,
            firstPerson: firstPerson.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.firstPerson,
            secondPerson: secondPerson.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.secondPerson,
            speechStyle: speechStyle.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.speechStyle,
            appearance: appearance.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.appearance,
            personality: personality.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.personality,
            background: background.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.background
        )
    }

    func updateSelectedCharacterProfileField(_ field: CharacterProfileField, value: String) {
        guard permitsDocumentInteraction else { return }
        guard var current = selectedCharacter else { return }
        let normalized = Self.nilIfBlank(value)

        switch field {
        case .role:
            current.role = normalized
        case .age:
            current.age = normalized
        case .gender:
            current.gender = normalized
        case .firstPerson:
            current.firstPerson = normalized
        case .secondPerson:
            current.secondPerson = normalized
        case .speechStyle:
            current.speechStyle = normalized
        case .appearance:
            current.appearance = normalized
        case .personality:
            current.personality = normalized
        case .background:
            current.background = normalized
        }

        document.updateCharacter(
            id: current.id,
            name: current.name,
            kana: current.kana,
            memo: current.memo,
            colorHex: current.colorHex,
            role: current.role,
            age: current.age,
            gender: current.gender,
            firstPerson: current.firstPerson,
            secondPerson: current.secondPerson,
            speechStyle: current.speechStyle,
            appearance: current.appearance,
            personality: current.personality,
            background: current.background
        )
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の登場人物カラーを更新する。`nil` はカラーなしを表す。
    func updateSelectedCharacterColor(_ colorHex: String?) {
        guard permitsDocumentInteraction else { return }
        guard let selectedCharacterID, let current = selectedCharacter else { return }
        guard current.colorHex != colorHex else { return }

        document.updateCharacter(
            id: selectedCharacterID,
            name: current.name,
            kana: current.kana,
            memo: current.memo,
            colorHex: colorHex,
            role: current.role,
            age: current.age,
            gender: current.gender,
            firstPerson: current.firstPerson,
            secondPerson: current.secondPerson,
            speechStyle: current.speechStyle,
            appearance: current.appearance,
            personality: current.personality,
            background: current.background
        )
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 登場人物名の編集確定時に、空名を正規化して即時保存へ寄せる。
    func commitCharacterEditing() {
        guard permitsDocumentInteraction else { return }
        for character in document.characters {
            let normalizedName = NovelDocument.normalizedCharacterName(character.name)
            if character.name != normalizedName {
                document.updateCharacter(
                    id: character.id,
                    name: normalizedName,
                    kana: character.kana,
                    memo: character.memo,
                    colorHex: character.colorHex,
                    role: character.role,
                    age: character.age,
                    gender: character.gender,
                    firstPerson: character.firstPerson,
                    secondPerson: character.secondPerson,
                    speechStyle: character.speechStyle,
                    appearance: character.appearance,
                    personality: character.personality,
                    background: character.background
                )
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 登場人物を削除する。
    @discardableResult
    func deleteCharacter(id: CharacterID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let originalIndex = document.characters.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removeCharacter(id: id) != nil else { return false }

        if selectedCharacterID == id {
            let fallbackIndex = min(originalIndex, document.characters.count - 1)
            selectedCharacterID = document.characters.indices.contains(fallbackIndex) ?
                document.characters[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 登場人物を並べ替える。
    func moveCharacters(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveCharacters(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    // MARK: - プロットカード

    /// プロットカードを追加し、追加したカードを選択状態にする。
    func addPlotCard(chapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        let newID = document.addPlotCard(title: "新しいカード", chapterID: chapterID)
        selectedPlotCardID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// プロットカードを選択する。
    func selectPlotCard(_ id: PlotCardID?) {
        guard permitsDocumentInteraction else { return }
        selectedPlotCardID = id
    }

    /// 選択中のプロットカードを更新する。
    func updateSelectedPlotCard(title: String? = nil, memo: String? = nil, chapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        guard let selectedPlotCardID, let current = selectedPlotCard else { return }
        let nextTitle = title ?? current.title
        let nextMemo = memo ?? current.memo
        let nextChapterID = chapterID ?? current.chapterID

        guard current.title != nextTitle || current.memo != nextMemo || current.chapterID != nextChapterID else {
            return
        }

        document.updatePlotCard(id: selectedPlotCardID, title: nextTitle, memo: nextMemo, chapterID: nextChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中のプロットカードの章紐付けを更新する。`nil` は未紐付けを表す。
    func updateSelectedPlotCardChapter(_ chapterID: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard let selectedPlotCardID, let current = selectedPlotCard else { return }
        guard current.chapterID != chapterID else { return }

        document.updatePlotCard(id: selectedPlotCardID, title: current.title, memo: current.memo, chapterID: chapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// プロットカードタイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitPlotCardEditing() {
        guard permitsDocumentInteraction else { return }
        for card in document.plotCards {
            let normalizedTitle = NovelDocument.normalizedPlotCardTitle(card.title)
            if card.title != normalizedTitle {
                document.updatePlotCard(id: card.id, title: normalizedTitle, memo: card.memo, chapterID: card.chapterID)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// プロットカードを削除する。
    @discardableResult
    func deletePlotCard(id: PlotCardID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let originalIndex = document.plotCards.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removePlotCard(id: id) != nil else { return false }

        if selectedPlotCardID == id {
            let fallbackIndex = min(originalIndex, document.plotCards.count - 1)
            selectedPlotCardID = document.plotCards.indices.contains(fallbackIndex) ?
                document.plotCards[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// プロットカードを並べ替える。
    func movePlotCards(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.movePlotCards(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// プロットカードを章レーン内/レーン間で移動する。
    func movePlotCard(id: PlotCardID, toChapter chapterID: ChapterID?, before targetID: PlotCardID? = nil) {
        guard permitsDocumentInteraction else { return }
        document.movePlotCard(id: id, toChapter: chapterID, before: targetID)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// Plot Outlineへのdropとしてカードの所属先を変更する。
    /// 存在しないカード／章、および現在と同じ所属先へのdropは拒否する。
    @discardableResult
    func movePlotCardFromOutline(id: PlotCardID, to selection: PlotOutlineSelection) -> Bool {
        guard permitsDocumentInteraction else { return false }
        guard let card = document.plotCards.first(where: { $0.id == id }) else { return false }

        let destinationChapterID: ChapterID?
        switch selection {
        case .unassigned:
            destinationChapterID = nil
        case let .chapter(chapterID):
            guard document.chapters.contains(where: { $0.id == chapterID }) else { return false }
            destinationChapterID = chapterID
        }

        guard card.chapterID != destinationChapterID else { return false }

        document.movePlotCard(id: id, toChapter: destinationChapterID)
        selectedPlotCardID = id
        plotOutlineSelection = selection
        if let destinationChapterID {
            setSelection(chapterID: destinationChapterID, episodeID: preferredEpisodeID(in: destinationChapterID))
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    // MARK: - 伏線

    /// 伏線を追加し、追加した伏線を選択状態にする。
    func addFlag() {
        guard permitsDocumentInteraction else { return }
        let newID = document.addFlag(title: "新しい伏線", plantedChapterID: selectedChapterID)
        selectedFlagID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 伏線を選択する。
    func selectFlag(_ id: FlagID?) {
        guard permitsDocumentInteraction else { return }
        selectedFlagID = id
    }

    /// 選択中の伏線を更新する。
    func updateSelectedFlag(title: String? = nil, note: String? = nil) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        let nextTitle = title ?? next.title
        let nextNote = note ?? next.note

        guard next.title != nextTitle || next.note != nextNote else { return }

        next.title = nextTitle
        next.note = nextNote
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の章紐付けを更新する。
    func updateSelectedFlagChapters(plantedChapterID: ChapterID? = nil, resolvedChapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        let nextPlantedChapterID = plantedChapterID ?? next.plantedChapterID
        let nextResolvedChapterID = resolvedChapterID ?? next.resolvedChapterID

        guard next.plantedChapterID != nextPlantedChapterID || next.resolvedChapterID != nextResolvedChapterID else {
            return
        }

        next.plantedChapterID = nextPlantedChapterID
        next.resolvedChapterID = nextResolvedChapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の張った章を更新する。`nil` は未設定を表す。
    func updateSelectedFlagPlantedChapter(_ chapterID: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        guard next.plantedChapterID != chapterID else { return }

        next.plantedChapterID = chapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の回収章を更新する。`nil` は未設定を表す。
    func updateSelectedFlagResolvedChapter(_ chapterID: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        guard next.resolvedChapterID != chapterID else { return }

        next.resolvedChapterID = chapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の回収状態を反転する。
    func toggleSelectedFlagResolved() {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        next.isResolved.toggle()
        next.resolvedChapterID = next.isResolved ? selectedChapterID : nil
        document.updateFlag(next)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 伏線タイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitFlagEditing() {
        guard permitsDocumentInteraction else { return }
        for flag in document.flags {
            let normalizedTitle = NovelDocument.normalizedFlagTitle(flag.title)
            if flag.title != normalizedTitle {
                var next = flag
                next.title = normalizedTitle
                document.updateFlag(next)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 伏線を削除する。
    @discardableResult
    func deleteFlag(id: FlagID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let originalIndex = document.flags.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removeFlag(id: id) != nil else { return false }

        if selectedFlagID == id {
            let fallbackIndex = min(originalIndex, document.flags.count - 1)
            selectedFlagID = document.flags.indices.contains(fallbackIndex) ? document.flags[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 伏線を並べ替える。
    func moveFlags(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveFlags(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    // MARK: - 資料添付

    /// 現在のリポジトリが資料添付に対応しているか。
    var supportsAttachments: Bool {
        attachmentManager != nil
    }

    /// 資料一覧を保存層から再読み込みする。
    func reloadAttachments(expectedSession: DocumentSessionToken? = nil) async {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: ()) {
            let packageURL = documentURL
            attachments = await saveCoordinator.performExclusive {
                await loadAttachments(for: packageURL)
            }
        }
    }

    /// 外部ファイルを現在の作品へ資料として取り込む。
    ///
    /// 添付ファイルのコピーは大きなファイルだと数秒かかることがあり、その間に
    /// 本文編集のデバウンス保存(2秒)が発火すると、保存側は「取り込み中の古い
    /// attachments/ をコピーした作業ディレクトリ」でパッケージを全置換してしまい、
    /// 取り込んだ資料が失われる(Phase 4 レビュー F-A)。そこで、まず
    /// `saveCoordinator.saveNow()` で保留中の編集を先に排出したうえで、実際の
    /// ファイルコピーと一覧再読込みは `saveCoordinator.performExclusive` の中で
    /// 行い、その間は新しい保存が一切始まらないようにする。
    ///
    /// - Important: `saveNow()` は `performExclusive` の *外側* で呼ぶこと。
    ///   `performExclusive` の中から `saveNow()` を呼ぶと、排他区間そのものを
    ///   待つ形になりデッドロックする。
    @discardableResult
    func addAttachment(
        from sourceURL: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Attachment? {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: nil) {
            await addAttachmentSerially(from: sourceURL)
        }
    }

    private func addAttachmentSerially(from sourceURL: URL) async -> Attachment? {
        guard let attachmentManager else { return nil }
        guard await saveCoordinator.saveNow() else { return nil }
        let packageURL = documentURL

        return await saveCoordinator.performExclusive {
            do {
                let attachment = try await attachmentManager.addAttachment(from: sourceURL, to: packageURL)
                attachments = await loadAttachments(for: packageURL)
                return attachment
            } catch {
                print("[FUMINIWA] 資料の取り込みに失敗しました(\(sourceURL.path)): \(error)")
                return nil
            }
        }
    }

    /// 作品から資料を削除する。添付操作と保存の直列化は `addAttachment` と同じ理由
    /// (Phase 4 レビュー F-A)。
    func deleteAttachment(
        _ attachment: Attachment,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: false) {
            await deleteAttachmentSerially(attachment)
        }
    }

    private func deleteAttachmentSerially(_ attachment: Attachment) async -> Bool {
        guard let attachmentManager else { return false }
        guard await saveCoordinator.saveNow() else { return false }
        let packageURL = documentURL

        return await saveCoordinator.performExclusive {
            do {
                try await attachmentManager.deleteAttachment(named: attachment.fileName, from: packageURL)
                attachments = await loadAttachments(for: packageURL)
                return true
            } catch {
                print("[FUMINIWA] 資料の削除に失敗しました(\(attachment.fileName)): \(error)")
                return false
            }
        }
    }

    /// プレビュー用の資料URLを返す。
    func attachmentPreviewURL(for attachment: Attachment) -> URL? {
        attachmentManager?.attachmentURL(named: attachment.fileName, in: documentURL)
    }

    /// 現在の作品状態をスナップショットとして保存する。
    ///
    /// まず通常保存を完了させてから、対応リポジトリにスナップショット作成を依頼する。
    /// 非対応リポジトリの場合は `nil` を返す。
    func createSnapshot(expectedSession: DocumentSessionToken? = nil) async -> URL? {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: nil) {
            await createSnapshotSerially()
        }
    }

    private func createSnapshotSerially() async -> URL? {
        guard let repository = repository as? SnapshottingDocumentRepository else { return nil }
        guard await saveCoordinator.saveNow() else { return nil }
        let documentSnapshot = document
        let packageURL = documentURL

        do {
            return try await saveCoordinator.performExclusive {
                try await repository.saveSnapshot(documentSnapshot, to: packageURL)
            }
        } catch {
            print("[FUMINIWA] スナップショット保存に失敗しました(\(packageURL.path)): \(error)")
            return nil
        }
    }

    /// 現在の作品パッケージに保存されているスナップショットを新しい順で返す。
    func listSnapshots(expectedSession: DocumentSessionToken? = nil) async -> [DocumentSnapshotInfo] {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: []) {
            await listSnapshotsSerially()
        }
    }

    private func listSnapshotsSerially() async -> [DocumentSnapshotInfo] {
        guard let repository = repository as? SnapshottingDocumentRepository else { return [] }
        let packageURL = documentURL

        do {
            return try await saveCoordinator.performExclusive {
                try await repository.listSnapshots(in: packageURL)
            }
        } catch {
            print("[FUMINIWA] スナップショット一覧の取得に失敗しました(\(packageURL.path)): \(error)")
            return []
        }
    }

    /// 指定スナップショットを現在の作品へ復元する。
    ///
    /// 復元は破壊的でないよう、現在状態を先にスナップショット化してから書き戻す。
    /// 失敗時は `documentURL` / 本文 / 資料一覧を切り替えない(docs/PHASE5.md 4.5-3a)。
    @discardableResult
    func restoreSnapshot(
        at snapshotURL: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: false) {
            await restoreSnapshotSerially(at: snapshotURL)
        }
    }

    private func restoreSnapshotSerially(at snapshotURL: URL) async -> Bool {
        guard let repository = repository as? SnapshottingDocumentRepository else { return false }

        let restoredDocument: NovelDocument
        let restoredAttachments: [Attachment]
        do {
            restoredDocument = try await repository.load(from: snapshotURL)
            restoredAttachments = try await loadAttachmentsThrowing(for: snapshotURL)
        } catch {
            print("[FUMINIWA] スナップショットの読み込みに失敗しました(\(snapshotURL.path)): \(error)")
            return false
        }

        guard beginDocumentTransition() else { return false }
        defer { endDocumentTransition() }
        guard await saveCoordinator.saveNow() else { return false }

        // ここから復元結果のinstallまでは編集面を閉じる。復元中の入力が退避後に
        // 失われることを防ぎ、保存Coordinatorにも現在作品を公開しない(D-041)。
        let currentDocument = document
        let packageURL = documentURL
        startupState = .loading

        // 復元前退避と書き戻しを同じ保存排他区間で行う。通常保存が間へ入り、
        // snapshot directoryやpackage全体を別revisionで置換することを防ぐ。
        do {
            try await saveCoordinator.performExclusive {
                _ = try await repository.saveSnapshot(currentDocument, to: packageURL)
                try await repository.restoreSnapshot(from: snapshotURL, into: packageURL)
                // 待機中の通常保存が復元前モデルを同じpackageへ戻さないよう、
                // 復元結果のinstallも排他区間内で確定する。
                installDocument(restoredDocument, at: packageURL, attachments: restoredAttachments)
            }
        } catch {
            startupState = .ready
            print("[FUMINIWA] スナップショットの退避または復元に失敗しました(\(snapshotURL.path)): \(error)")
            return false
        }

        return true
    }

    // MARK: - 保存

    /// アプリ終了前に、保留中のデバウンス保存をキャンセルして現在状態を保存する。
    func saveBeforeTermination() async -> Bool {
        if let terminationTask {
            return await terminationTask.value
        }

        isTerminationPending = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return true }
            let succeeded = await documentOperationGate.perform {
                await saveBeforeTerminationSerially()
            }
            if !succeeded {
                // 終了が取り消された後は、利用者が保存先や作品を変更して復旧できる。
                isTerminationPending = false
                terminationTask = nil
            }
            return succeeded
        }
        terminationTask = task
        return await task.value
    }

    private func saveBeforeTerminationSerially() async -> Bool {
        guard startupState.isReady else { return true }
        guard beginDocumentTransition() else { return false }
        let succeeded = await saveCoordinator.saveNow()
        if !succeeded {
            endDocumentTransition()
        }
        return succeeded
    }

    /// Fileメニューの明示保存。自動保存と同じ直列化経路を使う。
    @discardableResult
    func saveNow() async -> Bool {
        guard startupState.isReady else { return false }
        return await saveCoordinator.saveNow()
    }

    /// 保存失敗後に、現在の未保存 revision を明示的に再試行する。
    func retrySave() {
        guard startupState.isReady else { return }
        flushSaveImmediately()
    }

    /// 保留中のデバウンス保存をキャンセルし、即座に保存キューへ流す(fire-and-forget)。
    /// `saveCoordinator.saveNow()` 自体がデバウンスのキャンセルと dirty 分の
    /// 保存until-cleanを面倒見るため、ここでは呼び出すだけでよい。
    private func flushSaveImmediately() {
        guard startupState.isReady else { return }
        Task { await self.saveCoordinator.saveNow() }
    }

    private func handleSaveEvent(_ event: DocumentSaveCoordinator.SaveEvent) {
        switch event {
        case .dirty:
            saveState = .unsaved
        case .saving:
            saveState = .saving
        case .saved:
            saveState = .saved
        case .failed:
            saveState = .failed
        }
    }

    private func normalizedChapterTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の章" : trimmed
    }

    private func normalizedEpisodeTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Episode.defaultTitle : trimmed
    }

    private static func nilIfBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func loadAttachments(for url: URL) async -> [Attachment] {
        do {
            return try await loadAttachmentsThrowing(for: url)
        } catch {
            print("[FUMINIWA] 資料一覧の読み込みに失敗しました(\(url.path)): \(error)")
            return []
        }
    }

    private func loadAttachmentsThrowing(for url: URL) async throws -> [Attachment] {
        guard let attachmentManager else { return [] }
        return try await attachmentManager.listAttachments(in: url)
    }

    private func installDocument(_ newDocument: NovelDocument, at url: URL, attachments newAttachments: [Attachment]) {
        document = newDocument
        documentURL = url
        advanceDocumentSession(document: newDocument, url: url)
        editorContentGeneration &+= 1
        setInitialSelection(for: newDocument)
        selectedCharacterID = newDocument.characters.first?.id
        selectedPlotCardID = newDocument.plotCards.first?.id
        selectedFlagID = newDocument.flags.first?.id
        attachments = newAttachments
        saveState = .saved
        startupState = .ready
        rememberDocumentURL(url)
    }

    private func advanceDocumentSession(document: NovelDocument, url: URL) {
        documentSessionToken = DocumentSessionToken(
            generation: documentSessionToken.generation &+ 1,
            documentID: document.id,
            documentURL: url.standardizedFileURL
        )
    }

    private func setInitialSelection(for newDocument: NovelDocument) {
        lastSelectedEpisodeByChapter = [:]
        let chapterID = newDocument.chapters.first?.id
        let episodeID = newDocument.chapters.first?.episodes.first?.id
        setSelection(chapterID: chapterID, episodeID: episodeID)
        selectedWorldNoteID = newDocument.worldNotes.first?.id
        plotOutlineSelection = chapterID.map(PlotOutlineSelection.chapter) ?? .unassigned
    }

    private func setSelection(chapterID: ChapterID?, episodeID: EpisodeID?) {
        selectedChapterID = chapterID
        selectedEpisodeID = episodeID
        if let chapterID, let episodeID {
            lastSelectedEpisodeByChapter[chapterID] = episodeID
        }
        if let chapterID {
            plotOutlineSelection = .chapter(chapterID)
        }
        workspaceSelection.outlineItemID = chapterID.map { OutlineItemID(rawValue: $0.rawValue.uuidString) }
    }

    private func preferredEpisodeID(in chapterID: ChapterID) -> EpisodeID? {
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else { return nil }
        if let remembered = lastSelectedEpisodeByChapter[chapterID], chapter.episodes.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return chapter.episodes.first?.id
    }

    private func observeResignActive() {
        guard resignActiveObserver.value == nil else { return }
        resignActiveObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.flushSaveImmediately()
            }
        }
    }

    private func rememberDocumentURL(_ url: URL) {
        userDefaults.set(url.path, forKey: Self.recentDocumentPathKey)
    }

    // MARK: - 既定の保存先

    private static func defaultDirectory(fileManager: FileManager, directoryName: String) -> URL {
        #if DEBUG
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent("Drafts", isDirectory: true)
        }
        #endif
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func defaultSaveURL(
        forTitle title: String,
        fileManager: FileManager,
        directoryName: String
    ) -> URL {
        defaultDirectory(fileManager: fileManager, directoryName: directoryName)
            .appendingPathComponent("\(title).novelpkg", isDirectory: true)
    }

    /// 既定保存先の `<title>.novelpkg` を返す。
    /// 既に同名のパッケージが存在する場合は連番を振って重複を避ける。
    private static func availableSaveURL(
        forTitle title: String,
        fileManager: FileManager,
        directoryName: String
    ) -> URL {
        let directory = defaultDirectory(fileManager: fileManager, directoryName: directoryName)

        var candidate = directory.appendingPathComponent("\(title).novelpkg", isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(title)\(suffix).novelpkg", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    #if DEBUG
    private static func shouldSkipRecentDocumentInDebug(_ url: URL, fileManager: FileManager) -> Bool {
        let path = url.standardizedFileURL.path
        if path.contains("/Library/Mobile Documents/") {
            return true
        }

        let documentsPath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .standardizedFileURL
            .path
        return path == documentsPath || path.hasPrefix(documentsPath + "/")
    }
    #endif
}
