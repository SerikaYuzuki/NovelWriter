import AppKit
import Foundation
import NovelCore
import NovelExport
import Observation
import UniformTypeIdentifiers

/// 書き出し形式と保存先を選ぶmacOS UIの境界。
///
/// `ExportPresenter` は具体的な `NSAlert` / `NSSavePanel` を知らず、テストでは
/// この境界を差し替えてキャンセルや選択結果を再現する。
@MainActor
protocol ExportPanelPresenting {
    func chooseFormat() -> AppExportFormat?
    func chooseDestination(format: AppExportFormat, defaultFilename: String) -> URL?
}

/// 利用者が選べる書き出し形式。
///
/// 原稿レンダリングは`NovelExport`へ委譲し、portableな作品パッケージは
/// AppStateの作品ライフサイクル境界から複製する。後者を`ExportFormat`へ
/// 混ぜないことで、NovelExportをpackage storageへ依存させない。
enum AppExportFormat: Hashable, Sendable {
    case rendered(ExportFormat)
    case novelPackage

    static let plainText = Self.rendered(.plainText)
    static let markdown = Self.rendered(.markdown)
    static let epub = Self.rendered(.epub)

    var filenameExtension: String {
        switch self {
        case let .rendered(format):
            format.filenameExtension
        case .novelPackage:
            "novelpkg"
        }
    }

    var displayName: String {
        switch self {
        case let .rendered(format):
            format.displayName
        case .novelPackage:
            "作品パッケージ"
        }
    }
}

/// 値スナップショットを指定形式で書き出す実行境界。
protocol ExportExecuting: Sendable {
    func export(
        _ document: NovelDocument,
        to destination: URL,
        format: ExportFormat
    ) async throws
}

/// MainActorから重い同期レンダリング／書き込みを分離する本番実装。
struct BackgroundNovelExportExecutor: ExportExecuting {
    func export(
        _ document: NovelDocument,
        to destination: URL,
        format: ExportFormat
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try NovelExporter().export(
                document,
                to: destination,
                options: ExportOptions(format: format)
            )
        }.value
    }
}

enum ExportPresentationState: Equatable {
    case idle
    case exporting(AppExportFormat)
    case succeeded(filename: String)
    case failed(message: String)
    case cancelled

    var isExporting: Bool {
        if case .exporting = self {
            return true
        }
        return false
    }

    var canDismiss: Bool {
        self != .idle && !isExporting
    }

    var message: String {
        switch self {
        case .idle:
            ""
        case let .exporting(format):
            "\(format.displayName)を書き出しています"
        case let .succeeded(filename):
            "「\(filename)」を書き出しました"
        case let .failed(message):
            message
        case .cancelled:
            "書き出しをキャンセルしました"
        }
    }

    var systemImage: String {
        switch self {
        case .idle, .exporting:
            "square.and.arrow.up"
        case .succeeded:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        case .cancelled:
            "xmark.circle"
        }
    }
}

/// Fileメニューとtoolbarの共通書き出しフロー。
///
/// パネル確定後に `documentProvider` を一度だけ評価し、その値を非同期実行境界へ
/// 渡す。AppStateの保存APIや `.novelpkg` の保存先には触れない。
@MainActor
@Observable
final class ExportPresenter {
    private let documentTitleProvider: @MainActor () -> String
    private let documentProvider: @MainActor () -> NovelDocument
    private let documentSessionProvider: @MainActor () -> DocumentSessionToken?
    @ObservationIgnored private let panelPresenter: any ExportPanelPresenting
    @ObservationIgnored private let executor: any ExportExecuting
    @ObservationIgnored private let packageExporter: @MainActor @Sendable (
        URL,
        DocumentSessionToken?
    ) async throws -> Void
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    private(set) var state: ExportPresentationState = .idle

    convenience init(appState: AppState) {
        self.init(
            documentTitleProvider: { appState.document.title },
            documentProvider: { appState.document },
            documentSessionProvider: { appState.documentSessionToken },
            panelPresenter: MacExportPanelPresenter(),
            executor: BackgroundNovelExportExecutor(),
            packageExporter: { destination, expectedSession in
                try await appState.exportDocumentPackage(
                    to: destination,
                    expectedSession: expectedSession
                )
            }
        )
    }

    init(
        documentTitleProvider: @escaping @MainActor () -> String,
        documentProvider: @escaping @MainActor () -> NovelDocument,
        documentSessionProvider: @escaping @MainActor () -> DocumentSessionToken? = { nil },
        panelPresenter: any ExportPanelPresenting,
        executor: any ExportExecuting,
        packageExporter: @escaping @MainActor @Sendable (
            URL,
            DocumentSessionToken?
        ) async throws -> Void = { _, _ in
            throw PackageExportError.unavailable
        }
    ) {
        self.documentTitleProvider = documentTitleProvider
        self.documentProvider = documentProvider
        self.documentSessionProvider = documentSessionProvider
        self.panelPresenter = panelPresenter
        self.executor = executor
        self.packageExporter = packageExporter
    }

    func present() {
        guard !state.isExporting else { return }
        exportTask = nil
        let expectedSession = documentSessionProvider()

        guard let format = panelPresenter.chooseFormat() else {
            state = .cancelled
            return
        }
        let defaultFilename = Self.defaultFilename(
            documentTitle: documentTitleProvider(),
            format: format
        )
        guard let selectedDestination = panelPresenter.chooseDestination(
            format: format,
            defaultFilename: defaultFilename
        ) else {
            state = .cancelled
            return
        }

        let destination = Self.enforcingExtension(format.filenameExtension, on: selectedDestination)
        guard documentSessionProvider() == expectedSession else {
            state = .failed(message: "作品が切り替わったため、書き出しを開始しませんでした。")
            return
        }
        let renderedDocument: NovelDocument? = if case .rendered = format {
            documentProvider()
        } else {
            nil
        }
        state = .exporting(format)

        exportTask = Task { [weak self, executor, packageExporter] in
            do {
                switch format {
                case let .rendered(renderedFormat):
                    // 保存パネル確定時のsessionと値を一度だけ捕捉する。
                    guard let documentSnapshot = renderedDocument else { throw CancellationError() }
                    try await executor.export(
                        documentSnapshot,
                        to: destination,
                        format: renderedFormat
                    )
                case .novelPackage:
                    // packageは現在Editorの確定と資料等の複製をAppStateのgate内で行う。
                    try await packageExporter(destination, expectedSession)
                }
                guard !Task.isCancelled else {
                    self?.state = .cancelled
                    return
                }
                self?.state = .succeeded(filename: destination.lastPathComponent)
            } catch is CancellationError {
                self?.state = .cancelled
            } catch {
                self?.state = .failed(message: Self.safeFailureMessage(for: error))
            }
        }
    }

    func dismissStatus() {
        guard state.canDismiss else { return }
        state = .idle
    }

    /// 非同期完了を待つテスト境界。UIからは使用しない。
    func waitForCurrentExport() async {
        await exportTask?.value
    }

    static func defaultFilename(documentTitle: String, format: AppExportFormat) -> String {
        let trimmedTitle = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? "無題の作品" : trimmedTitle
        return "\(title).\(format.filenameExtension)"
    }

    static func enforcingExtension(_ requiredExtension: String, on url: URL) -> URL {
        guard url.pathExtension.lowercased() != requiredExtension.lowercased() else { return url }
        return url.deletingPathExtension().appendingPathExtension(requiredExtension)
    }

    private static func safeFailureMessage(for error: Error) -> String {
        guard let exportError = error as? ExportError else {
            return "書き出しに失敗しました。保存先の空き容量やアクセス権限を確認してください。"
        }

        switch exportError {
        case .renderingFailed:
            return "書き出しデータを作成できませんでした。作品内容を確認して、もう一度お試しください。"
        case .invalidDestination:
            return "選択した保存先を使用できません。別の保存先を選んでください。"
        case .destinationPreparationFailed, .temporaryWriteFailed, .destinationReplacementFailed:
            return "保存先へ書き込めませんでした。空き容量やアクセス権限を確認してください。"
        }
    }
}

@MainActor
private final class MacExportPanelPresenter: ExportPanelPresenting {
    private let formats: [(format: AppExportFormat, title: String)] = [
        (.plainText, "テキスト（.txt）"),
        (.markdown, "Markdown（.md）"),
        (.epub, "EPUB（.epub）"),
        (.novelPackage, "ふみにわ作品パッケージ（.novelpkg）")
    ]

    func chooseFormat() -> AppExportFormat? {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        picker.addItems(withTitles: formats.map(\.title))
        picker.setAccessibilityLabel("書き出し形式")

        let alert = NSAlert()
        alert.messageText = "書き出し形式を選択"
        alert.informativeText = "原稿または作品パッケージを書き出す形式を選んでください。作品パッケージには、このMacにある作品内容・資料・スナップショット履歴が含まれます。iCloud上の完全なバックアップではありません。"
        alert.alertStyle = .informational
        alert.accessoryView = picker
        alert.addButton(withTitle: "続ける")
        alert.addButton(withTitle: "キャンセル")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let selectedIndex = picker.indexOfSelectedItem
        guard formats.indices.contains(selectedIndex) else { return nil }
        return formats[selectedIndex].format
    }

    func chooseDestination(format: AppExportFormat, defaultFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = format == .novelPackage ? "作品パッケージを書き出す" : "原稿を書き出す"
        panel.prompt = "書き出す"
        panel.nameFieldStringValue = defaultFilename
        panel.allowedContentTypes = [
            UTType(filenameExtension: format.filenameExtension) ?? .data
        ]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

private extension ExportFormat {
    var displayName: String {
        switch self {
        case .plainText:
            "テキスト"
        case .markdown:
            "Markdown"
        case .epub:
            "EPUB"
        }
    }
}

enum PackageExportError: Error {
    case unavailable
    case staleSession
    case invalidDestination
    case saveFailed
}
