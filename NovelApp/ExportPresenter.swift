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
    func chooseFormat() -> ExportFormat?
    func chooseDestination(format: ExportFormat, defaultFilename: String) -> URL?
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
    case exporting(ExportFormat)
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
    @ObservationIgnored private let panelPresenter: any ExportPanelPresenting
    @ObservationIgnored private let executor: any ExportExecuting
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    private(set) var state: ExportPresentationState = .idle

    convenience init(appState: AppState) {
        self.init(
            documentTitleProvider: { appState.document.title },
            documentProvider: { appState.document },
            panelPresenter: MacExportPanelPresenter(),
            executor: BackgroundNovelExportExecutor()
        )
    }

    init(
        documentTitleProvider: @escaping @MainActor () -> String,
        documentProvider: @escaping @MainActor () -> NovelDocument,
        panelPresenter: any ExportPanelPresenting,
        executor: any ExportExecuting
    ) {
        self.documentTitleProvider = documentTitleProvider
        self.documentProvider = documentProvider
        self.panelPresenter = panelPresenter
        self.executor = executor
    }

    func present() {
        guard !state.isExporting else { return }
        exportTask = nil

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

        // 保存パネル確定後の値を一度だけ捕捉する。以降の編集はこの値へ影響しない。
        let documentSnapshot = documentProvider()
        let destination = Self.enforcingExtension(format.filenameExtension, on: selectedDestination)
        state = .exporting(format)

        exportTask = Task { [weak self, executor] in
            do {
                try await executor.export(documentSnapshot, to: destination, format: format)
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

    static func defaultFilename(documentTitle: String, format: ExportFormat) -> String {
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
    private let formats: [(format: ExportFormat, title: String)] = [
        (.plainText, "テキスト（.txt）"),
        (.markdown, "Markdown（.md）"),
        (.epub, "EPUB（.epub）")
    ]

    func chooseFormat() -> ExportFormat? {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        picker.addItems(withTitles: formats.map(\.title))
        picker.setAccessibilityLabel("書き出し形式")

        let alert = NSAlert()
        alert.messageText = "書き出し形式を選択"
        alert.informativeText = "原稿を書き出す形式を選んでください。"
        alert.alertStyle = .informational
        alert.accessoryView = picker
        alert.addButton(withTitle: "続ける")
        alert.addButton(withTitle: "キャンセル")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let selectedIndex = picker.indexOfSelectedItem
        guard formats.indices.contains(selectedIndex) else { return nil }
        return formats[selectedIndex].format
    }

    func chooseDestination(format: ExportFormat, defaultFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "原稿を書き出す"
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
