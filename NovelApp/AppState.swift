import AppKit
import Foundation
import NovelCore
import Observation

/// アプリ全体の状態を管理する(docs/DESIGN.md 5.2)。
///
/// 責務:
/// - 現在開いている作品(`document`)と選択中の章ID(`selection`)の保持
/// - 選択中章の取得・本文更新(ロジック自体は `NovelDocument` のヘルパーに委譲し、
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
    private(set) var selection: ChapterID?
    /// 現在の保存先 URL(`.novelpkg` パッケージ)。
    private(set) var documentURL: URL

    private let repository: DocumentRepository
    private let userDefaults: UserDefaults
    private let fileManager: FileManager

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
        }
    )
    /// `deinit` は MainActor 分離を持たない(nonisolated)ため、そこから触れるように
    /// `nonisolated(unsafe)` にする。実際の読み書きは init/メソッド(MainActor)と
    /// deinit(このインスタンスへの参照がなくなった後、一度だけ)からのみで、
    /// 競合アクセスは発生しない。
    private nonisolated(unsafe) var resignActiveObserver: NSObjectProtocol?

    private static let recentDocumentPathKey = "dev.serikayuzuki.NovelWriter.recentDocumentPath"
    private static let autosaveDebounceNanoseconds: UInt64 = 2_000_000_000

    init(dependencies: AppDependencies) {
        repository = dependencies.repository
        userDefaults = dependencies.userDefaults
        fileManager = dependencies.fileManager

        // 実際の状態は `bootstrap()` で確立する。ここでは(ウィンドウ表示を
        // ブロックしないよう)空の新規作品をプレースホルダとして持たせておく。
        let placeholder = NovelDocument.newDocument()
        document = placeholder
        documentURL = Self.defaultSaveURL(forTitle: placeholder.title, fileManager: dependencies.fileManager)
        selection = placeholder.chapters.first?.id
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
            do {
                let loaded = try await repository.load(from: url)
                document = loaded
                documentURL = url
                selection = loaded.chapters.first?.id
                return
            } catch {
                // 読み込みに失敗しても執筆継続を優先し、新規作品の作成にフォールバックする。
                print("NovelWriter: 前回の作品の読み込みに失敗しました(\(url.path)): \(error)")
            }
        }

        let newDocument = NovelDocument.newDocument()
        let newURL = Self.availableSaveURL(forTitle: newDocument.title, fileManager: fileManager)
        document = newDocument
        documentURL = newURL
        selection = newDocument.chapters.first?.id

        saveCoordinator.markDirty()
        await saveCoordinator.saveNow()
        rememberDocumentURL(newURL)
    }

    // MARK: - 選択中章

    /// 選択中の章(存在しなければ `nil`)。
    var selectedChapter: Chapter? {
        guard let selection else { return nil }
        return document.chapters.first { $0.id == selection }
    }

    /// 章を選択する。選択が変わるたびに即座に保存する(docs/DESIGN.md 6.4)。
    func selectChapter(_ id: ChapterID?) {
        guard id != selection else { return }
        selection = id
        flushSaveImmediately()
    }

    // MARK: - 章操作(ロジックは NovelDocument 側のヘルパーに委譲)

    /// 章を末尾に追加し、追加した章を選択状態にする。
    func addChapter() {
        let title = "第\(document.chapters.count + 1)章"
        let newID = document.addChapter(title: title)
        selection = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
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

        if selection == id {
            let fallbackIndex = min(originalIndex, document.chapters.count - 1)
            selection = document.chapters.indices.contains(fallbackIndex) ? document.chapters[fallbackIndex].id : nil
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

    /// 選択中章の本文を更新する。編集のたびに呼ばれる想定で、モデル更新は即座に行い、
    /// ディスクへの保存は2秒デバウンスする(テキスト所有権ルール D-005。
    /// `EditorView` から編集中に本文を書き戻すことはしない)。
    func updateSelectedChapterContent(_ content: String) {
        guard let selection else { return }
        guard document.chapters.first(where: { $0.id == selection })?.content != content else { return }
        document.updateContent(content, for: selection)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中章のメモを更新する。メモは短文想定の補助情報なので SwiftUI 側の
    /// `TextEditor` から通常の Binding 更新で呼ばれる。
    func updateSelectedChapterMemo(_ memo: String) {
        guard let selection else { return }
        guard document.chapters.first(where: { $0.id == selection })?.memo != memo else { return }
        document.updateMemo(memo, for: selection)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
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

    // MARK: - 保存

    /// アプリ終了前に、保留中のデバウンス保存をキャンセルして現在状態を保存する。
    func saveBeforeTermination() async -> Bool {
        await saveCoordinator.saveNow()
    }

    /// 保留中のデバウンス保存をキャンセルし、即座に保存キューへ流す(fire-and-forget)。
    /// `saveCoordinator.saveNow()` 自体がデバウンスのキャンセルと dirty 分の
    /// 保存until-cleanを面倒見るため、ここでは呼び出すだけでよい。
    private func flushSaveImmediately() {
        Task { await self.saveCoordinator.saveNow() }
    }

    private func normalizedChapterTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の章" : trimmed
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
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("NovelWriter", isDirectory: true)
    }

    private static func defaultSaveURL(forTitle title: String, fileManager: FileManager) -> URL {
        defaultDirectory(fileManager: fileManager).appendingPathComponent("\(title).novelpkg", isDirectory: true)
    }

    /// `~/Documents/NovelWriter/<title>.novelpkg` を既定の保存先とする。
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
}
