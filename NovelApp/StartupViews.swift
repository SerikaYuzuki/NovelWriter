import AppKit
import SwiftUI

struct StartupLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("ふみにわ")
                    .font(.title2.weight(.semibold))
                Text("作品を準備しています…")
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("作品を準備中")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 640, minHeight: 420)
        .background(.background)
    }
}

struct StartupRecoveryView: View {
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter

    let context: StartupRecoveryContext

    @State private var confirmsNewDocument = false
    @State private var newDocumentSession: DocumentSessionToken?

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                title,
                systemImage: "book.closed.fill",
                description: Text(message)
            )

            HStack(spacing: 10) {
                if context.reason != .protectedLocationInDebugBuild {
                    Button("再試行") {
                        Task { await appState.retryStartup() }
                    }
                    .keyboardShortcut(.defaultAction)
                }

                if let finderURL {
                    Button(finderButtonTitle) {
                        NSWorkspace.shared.activateFileViewerSelecting([finderURL])
                    }
                }

                Button("別の作品を開く…") {
                    documentPanelPresenter.presentOpenPanel()
                }

                Button("新規作品を作る…") {
                    newDocumentSession = appState.documentSessionToken
                    confirmsNewDocument = true
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 680, minHeight: 440)
        .background(.background)
        .confirmationDialog(
            "新しい作品を作りますか？",
            isPresented: $confirmsNewDocument
        ) {
            Button("新規作品を作る") {
                guard let newDocumentSession else { return }
                documentPanelPresenter.presentNewDocument(expectedSession: newDocumentSession)
                self.newDocumentSession = nil
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("開けなかった作品は変更も削除もしません。新しい作品を保存できた後に、そちらへ切り替えます。")
        }
    }

    private var title: String {
        switch context.reason {
        case .cannotOpenDocument:
            "作品を安全に開けませんでした"
        case .cannotCreateDocument:
            "新しい作品を保存できませんでした"
        case .protectedLocationInDebugBuild:
            "開発版で実原稿を自動では開きません"
        }
    }

    private var finderURL: URL? {
        guard let documentURL = context.documentURL else { return nil }
        if context.reason == .cannotCreateDocument {
            return documentURL.deletingLastPathComponent()
        }
        return documentURL
    }

    private var finderButtonTitle: String {
        context.reason == .cannotCreateDocument ? "保存先を Finder で表示" : "Finder で表示"
    }

    private var message: String {
        switch context.reason {
        case .cannotOpenDocument:
            if let name = context.documentDisplayName {
                "「\(name)」は変更していません。再試行するか、Finder で原本を確認してください。"
            } else {
                "原稿は変更していません。再試行するか、別の作品を選んでください。"
            }
        case .cannotCreateDocument:
            "保存先の空き容量やアクセス権限を確認してください。保存に成功するまで最近使った作品は変更しません。"
        case .protectedLocationInDebugBuild:
            "実原稿への誤保存を防ぐためです。内容を確認したうえで「別の作品を開く…」から明示的に選んでください。"
        }
    }
}
