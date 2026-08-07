import AppKit
import Foundation
import Observation

/// File メニューの「新規」「開く…」「別名で保存…」「Finder で表示」を担う薄い層
/// (docs/PHASE5.md 4.5-2b)。
///
/// `NSOpenPanel` / `NSSavePanel` の生成と結果の取り扱いをここに閉じ込め、
/// 実際の作品ライフサイクル操作は 4.5-2a で実装済みの `AppState` の
/// 既存API(`openDocument(at:)` / `createNewDocument()` / `saveDocument(as:)`)
/// だけを呼ぶ。`.novelpkg`のUTTypeはD-038でInfo.plistと同時に宣言する。
@MainActor
@Observable
final class DocumentPanelPresenter {
    private static let packageExtension = "novelpkg"

    private let appState: AppState

    /// ユーザーへ見せる失敗メッセージ。`nil` ならアラートを表示しない。
    var alertMessage: String?

    init(appState: AppState) {
        self.appState = appState
    }

    /// 「新規」。既定保存先へ作品を作成する。失敗時はアラートで知らせる。
    func presentNewDocument() {
        Task {
            let success = await appState.createNewDocument()
            if !success {
                alertMessage = "新規作品を作成できませんでした。保存先の空き容量やアクセス権限を確認してください。"
            }
        }
    }

    /// 「開く…」。`.novelpkg` パッケージを選ばせ、`AppState.openDocument(at:)` へ渡す。
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "作品を開く"
        panel.prompt = "開く"
        panel.allowedContentTypes = [.fuminiwaNovelPackage]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            // キャンセルは状態を変えない。
            return
        }

        guard url.pathExtension.lowercased() == Self.packageExtension else {
            alertMessage = "「.novelpkg」形式の作品フォルダを選択してください。"
            return
        }

        Task {
            let success = await appState.openDocument(at: url)
            if !success {
                alertMessage = "作品を開けませんでした。ファイルが壊れているか、アクセス権限がない可能性があります。"
            }
        }
    }

    /// 「別名で保存…」。既定ファイル名は現在の作品タイトルとし、拡張子は `.novelpkg` を強制する。
    func presentSaveAsPanel() {
        let panel = NSSavePanel()
        panel.title = "別名で保存"
        panel.prompt = "保存"
        panel.allowedContentTypes = [.fuminiwaNovelPackage]
        panel.nameFieldStringValue = "\(appState.document.title).\(Self.packageExtension)"
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, var url = panel.url else {
            // キャンセルは状態を変えない。
            return
        }

        if url.pathExtension.lowercased() != Self.packageExtension {
            url = url.deletingPathExtension().appendingPathExtension(Self.packageExtension)
        }

        Task {
            let success = await appState.saveDocument(as: url)
            if !success {
                alertMessage = "別名で保存できませんでした。保存先の空き容量やアクセス権限を確認してください。"
            }
        }
    }

    /// 「Finder で表示」。現在の保存先を Finder で選択状態にする。
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([appState.documentURL])
    }
}
