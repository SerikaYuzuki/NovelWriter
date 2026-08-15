import AppKit
import Foundation
import Observation

/// File メニューの「新しい作品」「作品を取り込む…」を担う薄い層。
///
/// `NSOpenPanel` / `NSSavePanel` の生成と結果の取り扱いをここに閉じ込め、
/// 実際の作品ライフサイクル操作は 4.5-2a で実装済みの `AppState` の
/// 標準版では外部packageをopen-in-placeせず、AppStateのprivate import境界へ渡す。
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
    func presentNewDocument(expectedSession: DocumentSessionToken? = nil) {
        guard appState.permitsDocumentChoice,
              appState.deviceSyncRuntime?.library == nil || appState.permitsCloudLibraryMutation else {
            return
        }
        let session = expectedSession ?? appState.documentSessionToken
        Task {
            let success = await appState.createNewDocument(expectedSession: session)
            if !success {
                if appState.documentSessionToken != session {
                    alertMessage = "作品が切り替わったため、新規作品は作成しませんでした。"
                } else {
                    alertMessage = "新規作品を作成できませんでした。保存先の空き容量やアクセス権限を確認してください。"
                }
            }
        }
    }

    /// 「作品を取り込む…」。標準版は検証済みprivate copyを新workとして作る。
    func presentOpenPanel(expectedSession: DocumentSessionToken? = nil) {
        guard appState.permitsDocumentChoice else { return }
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

        guard panel.runModal() == .OK, let url = panel.url else {
            // キャンセルは状態を変えない。
            return
        }

        guard url.pathExtension.lowercased() == Self.packageExtension else {
            alertMessage = "「.novelpkg」形式の作品フォルダを選択してください。"
            return
        }

        Task {
            let success = if appState.deviceSyncRuntime?.library != nil {
                await appState.importExternalDocument(at: url, expectedSession: session)
            } else {
                await appState.openDocument(at: url, expectedSession: session)
            }
            if !success {
                if appState.documentSessionToken != session {
                    alertMessage = "作品が切り替わったため、選択した作品は開きませんでした。"
                } else {
                    alertMessage = "作品を取り込めませんでした。原本は変更していません。形式、空き容量、アクセス権限を確認してください。"
                }
            }
        }
    }
}
