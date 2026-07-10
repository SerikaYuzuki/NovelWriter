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

/// アプリ全体の状態を管理する(docs/DESIGN.md 5.2)。
///
/// 責務:
/// - 現在開いている作品(`document`)と選択中の章／話IDの保持
/// - 選択中話の取得・本文更新(ロジック自体は `NovelDocument` のヘルパーに委譲し、
///   `AppState` は薄く保つ)
/// - 保存先 URL の保持と、「最近開いた作品」のファイルパスの記録(D-009。
///   App Sandbox 非採用のためセキュリティスコープ付きブックマークは不要 → D-011)
/// - 自動保存: 本文変更は2秒デバウンス、章切り替え時とアプリ非アクティブ時は即保存
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
    /// 原稿パッケージの保存状態。表示はこの値だけを正とする。
    private(set) var saveState: DocumentSaveState

    /// Project Sidebar と Outline の選択状態。UI2 以降の画面選択の正。
    private(set) var workspaceSelection: WorkspaceSelection {
        didSet {
            userDefaults.set(workspaceSelection.section.rawValue, forKey: Self.projectSectionKey)
        }
    }

    /// Outline の検索バーなど、表示専用の一時状態。
    var outlinePresentation = OutlinePresentationState()
    /// 下部 AI Assistant Panel の開閉・入力状態。
    var aiAssistantPanel = AIAssistantPanelState()

    /// 現在の作品に取り込まれている資料一覧。
    private(set) var attachments: [Attachment]
    /// 現在の保存先 URL(`.novelpkg` パッケージ)。
    private(set) var documentURL: URL

    private let repository: DocumentRepository
    private let attachmentManager: AttachmentManaging?
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
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
            guard let self else { return nil }
            return (document, documentURL)
        },
        saveOperation: { [weak self] doc, url in
            guard let self else { throw CancellationError() }
            do {
                try await repository.save(doc, to: url)
            } catch {
                // 保存失敗でアプリを落とさない。まずはログのみ残し、執筆継続を優先する。
                print("NovelWriter: 保存に失敗しました(\(url.path)): \(error)")
                throw error
            }
        },
        saveEventHandler: { [weak self] event in
            self?.handleSaveEvent(event)
        }
    )
    /// `deinit` は MainActor 分離を持たない(nonisolated)ため、そこから触れるように
    /// `nonisolated(unsafe)` にする。実際の読み書きは init/メソッド(MainActor)と
    /// deinit(このインスタンスへの参照がなくなった後、一度だけ)からのみで、
    /// 競合アクセスは発生しない。
    private nonisolated(unsafe) var resignActiveObserver: NSObjectProtocol?

    private static let recentDocumentPathKey = "dev.serikayuzuki.NovelWriter.recentDocumentPath"
    private static let projectSectionKey = "dev.serikayuzuki.NovelWriter.projectSection"
    private static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000

    init(dependencies: AppDependencies) {
        repository = dependencies.repository
        attachmentManager = dependencies.attachmentManager
        userDefaults = dependencies.userDefaults
        fileManager = dependencies.fileManager

        // 実際の状態は `bootstrap()` で確立する。ここでは(ウィンドウ表示を
        // ブロックしないよう)空の新規作品をプレースホルダとして持たせておく。
        let placeholder = NovelDocument.newDocument()
        document = placeholder
        documentURL = Self.defaultSaveURL(forTitle: placeholder.title, fileManager: dependencies.fileManager)
        selectedChapterID = placeholder.chapters.first?.id
        selectedEpisodeID = placeholder.chapters.first?.episodes.first?.id
        selectedCharacterID = nil
        selectedPlotCardID = nil
        selectedFlagID = nil
        saveState = .unsaved
        let storedSection = dependencies.userDefaults.string(forKey: Self.projectSectionKey) ?? ""
        workspaceSelection = WorkspaceSelection(
            section: ProjectSection(rawValue: storedSection) ?? .structure
        )
        attachments = []
    }

    deinit {
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
    }

    /// 起動時の読み込み/新規作成を行う。`NovelWriterApp` から一度だけ呼ばれる想定。
    ///
    /// UserDefaults に前回開いていたファイルパスがあればそれを読み込む。
    /// 無ければ(または読み込みに失敗すれば)新規作品を作り、既定の保存先へ保存する。
    func bootstrap() async {
        observeResignActive()

        if let path = userDefaults.string(forKey: Self.recentDocumentPathKey), !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            #if DEBUG
            if Self.shouldSkipRecentDocumentInDebug(url, fileManager: fileManager) {
                userDefaults.removeObject(forKey: Self.recentDocumentPathKey)
            } else {
                do {
                    let loaded = try await repository.load(from: url)
                    document = loaded
                    documentURL = url
                    setInitialSelection(for: loaded)
                    selectedCharacterID = loaded.characters.first?.id
                    selectedPlotCardID = loaded.plotCards.first?.id
                    selectedFlagID = loaded.flags.first?.id
                    attachments = await loadAttachments(for: url)
                    saveState = .saved
                    return
                } catch {
                    // 読み込みに失敗しても執筆継続を優先し、新規作品の作成にフォールバックする。
                    print("NovelWriter: 前回の作品の読み込みに失敗しました(\(url.path)): \(error)")
                }
            }
            #else
            do {
                let loaded = try await repository.load(from: url)
                document = loaded
                documentURL = url
                setInitialSelection(for: loaded)
                selectedCharacterID = loaded.characters.first?.id
                selectedPlotCardID = loaded.plotCards.first?.id
                selectedFlagID = loaded.flags.first?.id
                attachments = await loadAttachments(for: url)
                saveState = .saved
                return
            } catch {
                // 読み込みに失敗しても執筆継続を優先し、新規作品の作成にフォールバックする。
                print("NovelWriter: 前回の作品の読み込みに失敗しました(\(url.path)): \(error)")
            }
            #endif
        }

        let newDocument = NovelDocument.newDocument()
        let newURL = Self.availableSaveURL(forTitle: newDocument.title, fileManager: fileManager)
        document = newDocument
        documentURL = newURL
        setInitialSelection(for: newDocument)
        selectedCharacterID = nil
        selectedPlotCardID = nil
        selectedFlagID = nil
        attachments = []

        saveCoordinator.markDirty()
        await saveCoordinator.saveNow()
        attachments = await loadAttachments(for: newURL)
        rememberDocumentURL(newURL)
    }

    // MARK: - 作品ライフサイクル

    /// 現在の作品を失わず、指定 URL の作品へ切り替える。
    ///
    /// 読み込み結果は一時値に保持し、本文と資料一覧の両方を取得できた後で現在作品の
    /// 保留中保存を完了させる。保存または読み込みに失敗した場合は、現在の状態を
    /// 一切置き換えない。
    @discardableResult
    func openDocument(at url: URL) async -> Bool {
        let targetURL = url.standardizedFileURL
        guard targetURL != documentURL.standardizedFileURL else {
            return await saveCoordinator.saveNow()
        }

        let loadedDocument: NovelDocument
        let loadedAttachments: [Attachment]
        do {
            loadedDocument = try await repository.load(from: targetURL)
            loadedAttachments = try await loadAttachmentsThrowing(for: targetURL)
        } catch {
            print("NovelWriter: 作品の読み込みに失敗しました(\(targetURL.path)): \(error)")
            return false
        }

        // 読み込み待ちの間に現在作品が編集されても、ここで最新 revision まで保存する。
        // saveNow() から復帰した後は状態置換まで await しないため、未保存編集が
        // 切り替えとの隙間に入り込むことはない。
        guard await saveCoordinator.saveNow() else { return false }

        installDocument(loadedDocument, at: targetURL, attachments: loadedAttachments)
        return true
    }

    /// 新規作品を既定保存先へ作成し、保存成功後にだけ現在作品として採用する。
    @discardableResult
    func createNewDocument() async -> Bool {
        guard await saveCoordinator.saveNow() else { return false }

        let newDocument = NovelDocument.newDocument()
        let newURL = Self.availableSaveURL(forTitle: newDocument.title, fileManager: fileManager)
        let newAttachments: [Attachment]

        do {
            try await repository.save(newDocument, to: newURL)
            newAttachments = try await loadAttachmentsThrowing(for: newURL)
        } catch {
            print("NovelWriter: 新規作品の保存に失敗しました(\(newURL.path)): \(error)")
            return false
        }

        // 新規作品の書き込み中にも現在作品は編集できる。切り替え直前にもう一度
        // 保存キューを排出し、その編集を現在の保存先へ確実に残す。
        guard await saveCoordinator.saveNow() else { return false }

        installDocument(newDocument, at: newURL, attachments: newAttachments)
        return true
    }

    /// 現在作品を別 URL へ複製し、成功後にだけ保存先を切り替える。
    ///
    /// `DocumentCopyingRepository` が利用できる場合は、モデル外の資料・
    /// スナップショット・未知項目も保存層に引き継がせる。コピー中に生じた編集は
    /// dirty revision として残り、保存先切り替え後に新 URL へ保存される。
    @discardableResult
    func saveDocument(as url: URL) async -> Bool {
        let destinationURL = url.standardizedFileURL
        let sourceURL = documentURL

        guard destinationURL != sourceURL.standardizedFileURL else {
            return await saveCoordinator.saveNow()
        }
        guard await saveCoordinator.saveNow() else { return false }

        let documentSnapshot = document
        do {
            try await saveCoordinator.performExclusive {
                if let copyingRepository = repository as? DocumentCopyingRepository {
                    try await copyingRepository.saveCopy(
                        documentSnapshot,
                        from: sourceURL,
                        to: destinationURL
                    )
                } else {
                    try await repository.save(documentSnapshot, to: destinationURL)
                }
            }
        } catch {
            print("NovelWriter: 別名保存に失敗しました(\(destinationURL.path)): \(error)")
            return false
        }

        // コピー成功までは URL と最近使った作品を変更しない。コピー待ちの間に
        // 入った編集は同じ document 値に残っているため、切り替え後の saveNow()
        // が新 URL へ追記する。
        documentURL = destinationURL
        rememberDocumentURL(destinationURL)
        _ = await saveCoordinator.saveNow()
        return true
    }

    // MARK: - 選択中章

    /// Project Sidebar のセクションを選択する。UI2 では画面の主導線として使う。
    func selectProjectSection(_ section: ProjectSection) {
        guard workspaceSelection.section != section else { return }
        workspaceSelection = WorkspaceSelection(section: section)
    }

    /// 既存UIとの互換名。2cで `selectedChapterID` へ置き換える。
    var selection: ChapterID? {
        selectedChapterID
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

    /// 章を選択する。最後に選択していた話、なければ先頭の話も選択する。
    /// 選択が変わるたびに即座に保存する(docs/DESIGN.md 6.4)。
    func selectChapter(_ id: ChapterID?) {
        guard id != selectedChapterID else { return }
        setSelection(chapterID: id, episodeID: id.flatMap(preferredEpisodeID(in:)))
        flushSaveImmediately()
    }

    /// 話を選択する。`chapterID` を省略した場合は現在の章を対象にする。
    func selectEpisode(_ id: EpisodeID?, in chapterID: ChapterID? = nil) {
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
        let title = "第\(document.chapters.count + 1)章"
        let newID = document.addChapter(title: title)
        setSelection(chapterID: newID, episodeID: nil)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 指定章に話を追加し、追加した話を選択する。
    func addEpisode(to chapterID: ChapterID? = nil, title: String = Episode.defaultTitle) {
        let targetChapterID = chapterID ?? selectedChapterID
        guard let targetChapterID, let episodeID = document.addEpisode(to: targetChapterID, title: title) else { return }
        setSelection(chapterID: targetChapterID, episodeID: episodeID)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 選択中話のタイトルを更新する。
    func updateSelectedEpisodeTitle(_ title: String) {
        guard let selectedEpisodeID, let selectedChapterID else { return }
        guard selectedEpisode?.title != title else { return }
        document.updateEpisodeTitle(title, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 話のタイトルを更新する。
    func updateEpisodeTitle(_ title: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard document.episode(episodeID)?.episode.title != title else { return }
        document.updateEpisodeTitle(title, for: episodeID, in: chapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 章タイトルを更新する。タイトル編集中は頻繁に呼ばれるため保存はデバウンスする。
    func updateChapterTitle(_ title: String, for id: ChapterID) {
        guard document.chapters.first(where: { $0.id == id })?.title != title else { return }
        document.updateTitle(title, for: id)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// タイトル編集の確定時に、未保存分を即時保存へ寄せる。
    func commitChapterTitleEditing() {
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
    func deleteChapter(id: ChapterID) {
        guard document.chapters.count > 1 else { return }
        guard let originalIndex = document.chapters.firstIndex(where: { $0.id == id }) else { return }
        guard document.removeChapter(id: id) != nil else { return }

        if selectedChapterID == id {
            let fallbackIndex = min(originalIndex, document.chapters.count - 1)
            let fallbackChapterID = document.chapters.indices.contains(fallbackIndex) ? document.chapters[fallbackIndex].id : nil
            setSelection(chapterID: fallbackChapterID, episodeID: fallbackChapterID.flatMap(preferredEpisodeID(in:)))
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 章を並べ替える(`List.onMove` からそのまま呼べる形)。
    func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        document.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 話を削除し、同じ章の隣接話へ選択を移す。
    @discardableResult
    func deleteEpisode(id episodeID: EpisodeID, from chapterID: ChapterID? = nil) -> Bool {
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
        guard selectedEpisode?.content != content else { return }
        document.updateEpisodeContent(content, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 既存UIとの互換名。2cで話単位APIへ置き換える。
    func updateSelectedChapterContent(_ content: String) {
        updateSelectedEpisodeContent(content)
    }

    /// 選択中章のメモを更新する。メモは短文想定の補助情報なので SwiftUI 側の
    /// `TextEditor` から通常の Binding 更新で呼ばれる。
    func updateSelectedEpisodeMemo(_ memo: String) {
        guard let selectedChapterID, let selectedEpisodeID else { return }
        guard selectedEpisode?.memo != memo else { return }
        document.updateEpisodeMemo(memo, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 既存UIとの互換名。2cで話単位APIへ置き換える。
    func updateSelectedChapterMemo(_ memo: String) {
        updateSelectedEpisodeMemo(memo)
    }

    // MARK: - 登場人物

    /// 登場人物を追加し、追加した人物を選択状態にする。
    func addCharacter() {
        let newID = document.addCharacter(name: "名無し")
        selectedCharacterID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 登場人物を選択する。
    func selectCharacter(_ id: CharacterID?) {
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
    func deleteCharacter(id: CharacterID) {
        guard let originalIndex = document.characters.firstIndex(where: { $0.id == id }) else { return }
        guard document.removeCharacter(id: id) != nil else { return }

        if selectedCharacterID == id {
            let fallbackIndex = min(originalIndex, document.characters.count - 1)
            selectedCharacterID = document.characters.indices.contains(fallbackIndex) ?
                document.characters[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 登場人物を並べ替える。
    func moveCharacters(fromOffsets: IndexSet, toOffset: Int) {
        document.moveCharacters(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    // MARK: - プロットカード

    /// プロットカードを追加し、追加したカードを選択状態にする。
    func addPlotCard(chapterID: ChapterID? = nil) {
        let newID = document.addPlotCard(title: "新しいカード", chapterID: chapterID)
        selectedPlotCardID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// プロットカードを選択する。
    func selectPlotCard(_ id: PlotCardID?) {
        selectedPlotCardID = id
    }

    /// 選択中のプロットカードを更新する。
    func updateSelectedPlotCard(title: String? = nil, memo: String? = nil, chapterID: ChapterID? = nil) {
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
        guard let selectedPlotCardID, let current = selectedPlotCard else { return }
        guard current.chapterID != chapterID else { return }

        document.updatePlotCard(id: selectedPlotCardID, title: current.title, memo: current.memo, chapterID: chapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// プロットカードタイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitPlotCardEditing() {
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
    func deletePlotCard(id: PlotCardID) {
        guard let originalIndex = document.plotCards.firstIndex(where: { $0.id == id }) else { return }
        guard document.removePlotCard(id: id) != nil else { return }

        if selectedPlotCardID == id {
            let fallbackIndex = min(originalIndex, document.plotCards.count - 1)
            selectedPlotCardID = document.plotCards.indices.contains(fallbackIndex) ?
                document.plotCards[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// プロットカードを並べ替える。
    func movePlotCards(fromOffsets: IndexSet, toOffset: Int) {
        document.movePlotCards(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// プロットカードを章レーン内/レーン間で移動する。
    func movePlotCard(id: PlotCardID, toChapter chapterID: ChapterID?, before targetID: PlotCardID? = nil) {
        document.movePlotCard(id: id, toChapter: chapterID, before: targetID)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    // MARK: - 伏線

    /// 伏線を追加し、追加した伏線を選択状態にする。
    func addFlag() {
        let newID = document.addFlag(title: "新しい伏線", plantedChapterID: selection)
        selectedFlagID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 伏線を選択する。
    func selectFlag(_ id: FlagID?) {
        selectedFlagID = id
    }

    /// 選択中の伏線を更新する。
    func updateSelectedFlag(title: String? = nil, note: String? = nil) {
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
        guard var next = selectedFlag else { return }
        guard next.plantedChapterID != chapterID else { return }

        next.plantedChapterID = chapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の回収章を更新する。`nil` は未設定を表す。
    func updateSelectedFlagResolvedChapter(_ chapterID: ChapterID?) {
        guard var next = selectedFlag else { return }
        guard next.resolvedChapterID != chapterID else { return }

        next.resolvedChapterID = chapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の回収状態を反転する。
    func toggleSelectedFlagResolved() {
        guard var next = selectedFlag else { return }
        next.isResolved.toggle()
        next.resolvedChapterID = next.isResolved ? selection : nil
        document.updateFlag(next)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 伏線タイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitFlagEditing() {
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
    func deleteFlag(id: FlagID) {
        guard let originalIndex = document.flags.firstIndex(where: { $0.id == id }) else { return }
        guard document.removeFlag(id: id) != nil else { return }

        if selectedFlagID == id {
            let fallbackIndex = min(originalIndex, document.flags.count - 1)
            selectedFlagID = document.flags.indices.contains(fallbackIndex) ? document.flags[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 伏線を並べ替える。
    func moveFlags(fromOffsets: IndexSet, toOffset: Int) {
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
    func reloadAttachments() async {
        attachments = await loadAttachments(for: documentURL)
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
    func addAttachment(from sourceURL: URL) async -> Attachment? {
        guard let attachmentManager else { return nil }
        guard await saveCoordinator.saveNow() else { return nil }

        return await saveCoordinator.performExclusive {
            do {
                let attachment = try await attachmentManager.addAttachment(from: sourceURL, to: documentURL)
                attachments = await loadAttachments(for: documentURL)
                return attachment
            } catch {
                print("NovelWriter: 資料の取り込みに失敗しました(\(sourceURL.path)): \(error)")
                return nil
            }
        }
    }

    /// 作品から資料を削除する。添付操作と保存の直列化は `addAttachment` と同じ理由
    /// (Phase 4 レビュー F-A)。
    func deleteAttachment(_ attachment: Attachment) async -> Bool {
        guard let attachmentManager else { return false }
        guard await saveCoordinator.saveNow() else { return false }

        return await saveCoordinator.performExclusive {
            do {
                try await attachmentManager.deleteAttachment(named: attachment.fileName, from: documentURL)
                attachments = await loadAttachments(for: documentURL)
                return true
            } catch {
                print("NovelWriter: 資料の削除に失敗しました(\(attachment.fileName)): \(error)")
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
    func createSnapshot() async -> URL? {
        guard let repository = repository as? SnapshottingDocumentRepository else { return nil }
        guard await saveCoordinator.saveNow() else { return nil }

        do {
            return try await repository.saveSnapshot(document, to: documentURL)
        } catch {
            print("NovelWriter: スナップショット保存に失敗しました(\(documentURL.path)): \(error)")
            return nil
        }
    }

    /// 現在の作品パッケージに保存されているスナップショットを新しい順で返す。
    func listSnapshots() async -> [DocumentSnapshotInfo] {
        guard let repository = repository as? SnapshottingDocumentRepository else { return [] }

        do {
            return try await repository.listSnapshots(in: documentURL)
        } catch {
            print("NovelWriter: スナップショット一覧の取得に失敗しました(\(documentURL.path)): \(error)")
            return []
        }
    }

    /// 指定スナップショットを現在の作品へ復元する。
    ///
    /// 復元は破壊的でないよう、現在状態を先にスナップショット化してから書き戻す。
    /// 失敗時は `documentURL` / 本文 / 資料一覧を切り替えない(docs/PHASE5.md 4.5-3a)。
    @discardableResult
    func restoreSnapshot(at snapshotURL: URL) async -> Bool {
        guard let repository = repository as? SnapshottingDocumentRepository else { return false }

        let restoredDocument: NovelDocument
        let restoredAttachments: [Attachment]
        do {
            restoredDocument = try await repository.load(from: snapshotURL)
            restoredAttachments = try await loadAttachmentsThrowing(for: snapshotURL)
        } catch {
            print("NovelWriter: スナップショットの読み込みに失敗しました(\(snapshotURL.path)): \(error)")
            return false
        }

        guard await saveCoordinator.saveNow() else { return false }

        // 復元前の現在状態を退避する。ここが失敗したら現在作品を書き換えない。
        do {
            _ = try await repository.saveSnapshot(document, to: documentURL)
        } catch {
            print("NovelWriter: 復元前のスナップショット退避に失敗しました(\(documentURL.path)): \(error)")
            return false
        }

        let packageURL = documentURL
        do {
            try await saveCoordinator.performExclusive {
                try await repository.restoreSnapshot(from: snapshotURL, into: packageURL)
            }
        } catch {
            print("NovelWriter: スナップショットの復元に失敗しました(\(snapshotURL.path)): \(error)")
            return false
        }

        installDocument(restoredDocument, at: packageURL, attachments: restoredAttachments)
        return true
    }

    // MARK: - 保存

    /// アプリ終了前に、保留中のデバウンス保存をキャンセルして現在状態を保存する。
    func saveBeforeTermination() async -> Bool {
        await saveCoordinator.saveNow()
    }

    /// 保存失敗後に、現在の未保存 revision を明示的に再試行する。
    func retrySave() {
        flushSaveImmediately()
    }

    /// 保留中のデバウンス保存をキャンセルし、即座に保存キューへ流す(fire-and-forget)。
    /// `saveCoordinator.saveNow()` 自体がデバウンスのキャンセルと dirty 分の
    /// 保存until-cleanを面倒見るため、ここでは呼び出すだけでよい。
    private func flushSaveImmediately() {
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

    private static func nilIfBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func loadAttachments(for url: URL) async -> [Attachment] {
        do {
            return try await loadAttachmentsThrowing(for: url)
        } catch {
            print("NovelWriter: 資料一覧の読み込みに失敗しました(\(url.path)): \(error)")
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
        setInitialSelection(for: newDocument)
        selectedCharacterID = newDocument.characters.first?.id
        selectedPlotCardID = newDocument.plotCards.first?.id
        selectedFlagID = newDocument.flags.first?.id
        attachments = newAttachments
        saveState = .saved
        rememberDocumentURL(url)
    }

    private func setInitialSelection(for newDocument: NovelDocument) {
        lastSelectedEpisodeByChapter = [:]
        let chapterID = newDocument.chapters.first?.id
        let episodeID = newDocument.chapters.first?.episodes.first?.id
        setSelection(chapterID: chapterID, episodeID: episodeID)
    }

    private func setSelection(chapterID: ChapterID?, episodeID: EpisodeID?) {
        selectedChapterID = chapterID
        selectedEpisodeID = episodeID
        if let chapterID, let episodeID {
            lastSelectedEpisodeByChapter[chapterID] = episodeID
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
        resignActiveObserver = NotificationCenter.default.addObserver(
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

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        #if DEBUG
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent("NovelWriter", isDirectory: true)
                .appendingPathComponent("Drafts", isDirectory: true)
        }
        #endif
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("NovelWriter", isDirectory: true)
    }

    private static func defaultSaveURL(forTitle title: String, fileManager: FileManager) -> URL {
        defaultDirectory(fileManager: fileManager).appendingPathComponent("\(title).novelpkg", isDirectory: true)
    }

    /// 既定保存先の `<title>.novelpkg` を返す。
    /// 既に同名のパッケージが存在する場合は連番を振って重複を避ける。
    private static func availableSaveURL(forTitle title: String, fileManager: FileManager) -> URL {
        let directory = defaultDirectory(fileManager: fileManager)

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
