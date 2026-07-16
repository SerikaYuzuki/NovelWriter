import Foundation
import NovelCore
import NovelExport
@testable import NovelWriter
import Testing

@MainActor
struct ExportPresenterTests {
    @Test("選択形式の拡張子を既定名と保存先へ強制する", arguments: ExportFormat.allCases)
    func selectedFormatDeterminesFilenameExtension(format: ExportFormat) async throws {
        let panel = StubExportPanel(
            format: format,
            destination: URL(fileURLWithPath: "/tmp/原稿.invalid")
        )
        let executor = RecordingExportExecutor()
        var snapshotCount = 0
        let document = NovelDocument.newDocument(title: "銀河鉄道")
        let presenter = makePresenter(
            title: { document.title },
            document: {
                snapshotCount += 1
                return document
            },
            panel: panel,
            executor: executor
        )

        presenter.present()
        await presenter.waitForCurrentExport()

        let invocation = try #require(await executor.latestInvocation())
        #expect(panel.lastDefaultFilename == "銀河鉄道.\(format.filenameExtension)")
        #expect(invocation.destination.pathExtension == format.filenameExtension)
        #expect(invocation.format == format)
        #expect(snapshotCount == 1)
    }

    @Test("空の作品名は無題の作品を既定名にする")
    func blankTitleUsesFallbackFilename() {
        #expect(
            ExportPresenter.defaultFilename(documentTitle: " \n　", format: .epub)
                == "無題の作品.epub"
        )
    }

    @Test("形式選択のキャンセルではexportを呼ばない")
    func formatCancellationDoesNotExport() async {
        let panel = StubExportPanel(format: nil, destination: nil)
        let executor = RecordingExportExecutor()
        let presenter = makePresenter(panel: panel, executor: executor)

        presenter.present()
        await presenter.waitForCurrentExport()

        #expect(presenter.state == .cancelled)
        #expect(await executor.invocationCount() == 0)
        #expect(panel.destinationCallCount == 0)
    }

    @Test("保存パネルのキャンセルではexportを呼ばない")
    func destinationCancellationDoesNotExport() async {
        let panel = StubExportPanel(format: .markdown, destination: nil)
        let executor = RecordingExportExecutor()
        var snapshotCount = 0
        let presenter = makePresenter(
            document: {
                snapshotCount += 1
                return .newDocument()
            },
            panel: panel,
            executor: executor
        )

        presenter.present()
        await presenter.waitForCurrentExport()

        #expect(presenter.state == .cancelled)
        #expect(await executor.invocationCount() == 0)
        #expect(snapshotCount == 0)
    }

    @Test("export失敗は生のエラーを出さず安全な日本語を表示する")
    func failureShowsSafeMessage() async {
        let panel = StubExportPanel(
            format: .plainText,
            destination: URL(fileURLWithPath: "/tmp/失敗.txt")
        )
        let executor = RecordingExportExecutor(outcome: .failure)
        let presenter = makePresenter(panel: panel, executor: executor)

        presenter.present()
        await presenter.waitForCurrentExport()

        guard case let .failed(message) = presenter.state else {
            Issue.record("失敗状態になっていません")
            return
        }
        #expect(message.contains("書き出しに失敗しました"))
        #expect(!message.contains("internal-secret"))
    }

    @Test("export成功は確定したファイル名を表示する")
    func successShowsDestinationFilename() async {
        let panel = StubExportPanel(
            format: .markdown,
            destination: URL(fileURLWithPath: "/tmp/完成原稿")
        )
        let executor = RecordingExportExecutor()
        let presenter = makePresenter(panel: panel, executor: executor)

        presenter.present()
        await presenter.waitForCurrentExport()

        #expect(presenter.state == .succeeded(filename: "完成原稿.md"))
        presenter.dismissStatus()
        #expect(presenter.state == .idle)
    }

    @Test("実行中状態を表示し多重実行を防ぐ")
    func runningStatePreventsConcurrentExports() async {
        let panel = StubExportPanel(
            format: .epub,
            destination: URL(fileURLWithPath: "/tmp/実行中.epub")
        )
        let executor = RecordingExportExecutor(outcome: .suspended)
        let presenter = makePresenter(panel: panel, executor: executor)

        presenter.present()
        await executor.waitUntilStarted()

        #expect(presenter.state == .exporting(.epub))
        presenter.dismissStatus()
        #expect(presenter.state == .exporting(.epub))
        presenter.present()
        #expect(panel.formatCallCount == 1)
        #expect(await executor.invocationCount() == 1)

        await executor.resume()
        await presenter.waitForCurrentExport()
        #expect(presenter.state == .succeeded(filename: "実行中.epub"))
    }

    @Test("保存パネル確定後のsnapshotは開始後の編集から独立する")
    func exportUsesSingleSnapshotCapturedAfterPanelConfirmation() async throws {
        var currentDocument = NovelDocument.newDocument(title: "確定時作品")
        let panel = StubExportPanel(
            format: .plainText,
            destination: URL(fileURLWithPath: "/tmp/snapshot.txt")
        )
        panel.onChooseDestination = {
            currentDocument.chapters[0].episodes[0].content = "パネル確定時の本文"
        }
        let executor = RecordingExportExecutor(outcome: .suspended)
        var snapshotCount = 0
        let presenter = makePresenter(
            title: { currentDocument.title },
            document: {
                snapshotCount += 1
                return currentDocument
            },
            panel: panel,
            executor: executor
        )

        presenter.present()
        await executor.waitUntilStarted()
        currentDocument.chapters[0].episodes[0].content = "開始後に編集した本文"

        let invocation = try #require(await executor.latestInvocation())
        #expect(invocation.document.chapters[0].episodes[0].content == "パネル確定時の本文")
        #expect(snapshotCount == 1)

        await executor.resume()
        await presenter.waitForCurrentExport()
    }

    @Test("書き出しはrepository保存とnovelpkg URLを変更しない")
    func exportDoesNotSaveRepositoryOrChangeDocumentURL() async throws {
        let repository = ExportIsolationRepository()
        let defaultsFixture = makeUserDefaults()
        let defaults = defaultsFixture.defaults
        defer { defaults.removePersistentDomain(forName: defaultsFixture.suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportPresenterTests-\(UUID().uuidString)", isDirectory: true)
        let packageURL = directory.appendingPathComponent("Original.novelpkg", isDirectory: true)
        let attachmentsURL = packageURL.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sentinelURL = packageURL.appendingPathComponent("sentinel.bin")
        let attachmentURL = attachmentsURL.appendingPathComponent("reference.dat")
        let sentinelData = Data([0x00, 0x7F, 0xFF, 0x42])
        let attachmentData = Data("添付資料は変更しない".utf8)
        try sentinelData.write(to: sentinelURL)
        try attachmentData.write(to: attachmentURL)
        let sourceDocument = NovelDocument.newDocument(title: "分離テスト")
        await repository.seed(sourceDocument, at: packageURL)

        let appState = AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults
            )
        )
        #expect(await appState.openDocument(at: packageURL))
        await repository.resetSaveCount()
        let originalDocumentURL = appState.documentURL
        let originalPackagePaths = try relativePaths(in: packageURL)
        let panel = StubExportPanel(
            format: .plainText,
            destination: directory.appendingPathComponent("原稿.txt")
        )
        let presenter = ExportPresenter(
            documentTitleProvider: { appState.document.title },
            documentProvider: { appState.document },
            panelPresenter: panel,
            executor: BackgroundNovelExportExecutor()
        )

        presenter.present()
        await presenter.waitForCurrentExport()

        #expect(await repository.saveCount() == 0)
        #expect(appState.documentURL == originalDocumentURL)
        #expect(appState.documentURL.pathExtension == "novelpkg")
        #expect(try relativePaths(in: packageURL) == originalPackagePaths)
        #expect(try Data(contentsOf: sentinelURL) == sentinelData)
        #expect(try Data(contentsOf: attachmentURL) == attachmentData)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("原稿.txt").path))
    }

    private func makePresenter(
        title: @escaping @MainActor () -> String = { "テスト作品" },
        document: @escaping @MainActor () -> NovelDocument = { .newDocument(title: "テスト作品") },
        panel: StubExportPanel,
        executor: RecordingExportExecutor
    ) -> ExportPresenter {
        ExportPresenter(
            documentTitleProvider: title,
            documentProvider: document,
            panelPresenter: panel,
            executor: executor
        )
    }

    private func makeUserDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "ExportPresenterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func relativePaths(in directory: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return String(url.path.dropFirst(directory.path.count + 1))
        }.sorted()
    }
}

@MainActor
private final class StubExportPanel: ExportPanelPresenting {
    let format: ExportFormat?
    let destination: URL?
    var onChooseDestination: (() -> Void)?
    private(set) var formatCallCount = 0
    private(set) var destinationCallCount = 0
    private(set) var lastDefaultFilename: String?

    init(format: ExportFormat?, destination: URL?) {
        self.format = format
        self.destination = destination
    }

    func chooseFormat() -> ExportFormat? {
        formatCallCount += 1
        return format
    }

    func chooseDestination(format _: ExportFormat, defaultFilename: String) -> URL? {
        destinationCallCount += 1
        lastDefaultFilename = defaultFilename
        onChooseDestination?()
        return destination
    }
}

private actor RecordingExportExecutor: ExportExecuting {
    enum Outcome: Sendable {
        case success
        case failure
        case suspended
    }

    struct Invocation: Sendable {
        let document: NovelDocument
        let destination: URL
        let format: ExportFormat
    }

    private let outcome: Outcome
    private var invocations: [Invocation] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(outcome: Outcome = .success) {
        self.outcome = outcome
    }

    func export(_ document: NovelDocument, to destination: URL, format: ExportFormat) async throws {
        invocations.append(Invocation(document: document, destination: destination, format: format))
        if case .suspended = outcome {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        if case .failure = outcome {
            throw StubExportError.failure
        }
    }

    func waitUntilStarted() async {
        while invocations.isEmpty {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func latestInvocation() -> Invocation? {
        invocations.last
    }

    func invocationCount() -> Int {
        invocations.count
    }
}

private enum StubExportError: Error {
    case failure

    var localizedDescription: String {
        "internal-secret"
    }
}

private actor ExportIsolationRepository: DocumentRepository {
    private var saves = 0
    private var documents: [String: NovelDocument] = [:]

    func load(from url: URL) async throws -> NovelDocument {
        guard let document = documents[url.standardizedFileURL.path] else {
            throw ExportIsolationError.unexpectedLoad
        }
        return document
    }

    func save(_: NovelDocument, to _: URL) async throws {
        saves += 1
    }

    func saveCount() -> Int {
        saves
    }

    func seed(_ document: NovelDocument, at url: URL) {
        documents[url.standardizedFileURL.path] = document
    }

    func resetSaveCount() {
        saves = 0
    }
}

private enum ExportIsolationError: Error {
    case unexpectedLoad
}
