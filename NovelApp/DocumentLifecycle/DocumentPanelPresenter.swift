import AppKit
import Foundation
import Observation

/// File メニューの作品作成・明示的な `.novelpkg` 取り込みを担う薄い層。
/// 通常の作品identityと保存はAppStateのWorkID/SQLite v2境界が所有する。
@MainActor
@Observable
final class DocumentPanelPresenter {
    private static let packageExtension = "novelpkg"

    private let appState: AppState
    var alertMessage: String?

    init(appState: AppState) {
        self.appState = appState
    }

    func presentNewDocument(expectedSession: DocumentSessionToken? = nil) {
        guard appState.permitsDocumentTransitionOperation else { return }
        let session = expectedSession ?? appState.documentSessionToken
        Task {
            let success = await appState.createNewDocument(expectedSession: session)
            if !success {
                alertMessage = appState.documentSessionToken != session
                    ? "作品が切り替わったため、新規作品は作成しませんでした。"
                    : "新規作品を作成できませんでした。保存先の空き容量やアクセス権限を確認してください。"
            }
        }
    }

    func presentOpenPanel(expectedSession: DocumentSessionToken? = nil) {
        guard appState.permitsDocumentTransitionOperation else { return }
        let session = expectedSession ?? appState.documentSessionToken
        guard session == appState.documentSessionToken else { return }

        let panel = NSOpenPanel()
        panel.title = "作品を取り込む"
        panel.prompt = "取り込む"
        panel.allowedContentTypes = [.fuminiwaNovelPackage]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == Self.packageExtension else {
            alertMessage = "「.novelpkg」形式の作品フォルダを選択してください。"
            return
        }

        Task {
            let success = await appState.importExternalDocument(at: url, expectedSession: session)
            if !success {
                alertMessage = appState.documentSessionToken != session
                    ? "作品が切り替わったため、選択した作品は開きませんでした。"
                    : "作品を取り込めませんでした。原本は変更していません。形式、空き容量、アクセス権限を確認してください。"
            }
        }
    }
}
