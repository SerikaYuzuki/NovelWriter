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

    private var debouncedSaveTask: Task<Void, Never>?
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

        await save()
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
        flushSaveImmediately()
    }

    /// 章を並べ替える(`List.onMove` からそのまま呼べる形)。
    func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        document.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        flushSaveImmediately()
    }

    /// 選択中章の本文を更新する。編集のたびに呼ばれる想定で、モデル更新は即座に行い、
    /// ディスクへの保存は2秒デバウンスする(テキスト所有権ルール D-005。
    /// `EditorView` から編集中に本文を書き戻すことはしない)。
    func updateSelectedChapterContent(_ content: String) {
        guard let selection else { return }
        document.updateContent(content, for: selection)
        scheduleDebouncedSave()
    }

    // MARK: - 保存

    private func scheduleDebouncedSave() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autosaveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    private func flushSaveImmediately() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        Task { await self.save() }
    }

    private func save() async {
        do {
            try await repository.save(document, to: documentURL)
        } catch {
            // 保存失敗でアプリを落とさない。まずはログのみ残し、執筆継続を優先する。
            print("NovelWriter: 保存に失敗しました(\(documentURL.path)): \(error)")
        }
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
