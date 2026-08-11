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

struct StartupDocumentSelectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter

    let context: StartupDocumentSelectionContext

    @State private var selectedDocumentID: StartupRecentDocument.ID?

    init(context: StartupDocumentSelectionContext) {
        self.context = context
        _selectedDocumentID = State(initialValue: context.recentDocument?.id)
    }

    var body: some View {
        NavigationSplitView {
            recentDocumentsList
                .navigationSplitViewColumnWidth(min: 224, ideal: 264, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(.background)
        .accessibilityIdentifier("startup.documentSelection")
    }

    private var recentDocumentsList: some View {
        List(selection: $selectedDocumentID) {
            Section("最近使った作品") {
                if let recentDocument = context.recentDocument {
                    StartupRecentDocumentRow(document: recentDocument)
                        .tag(recentDocument.id)
                        .accessibilityIdentifier("startup.documentSelection.recent")
                } else {
                    Text("最近使った作品はありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("作品を選ぶ")
        .accessibilityIdentifier("startup.documentSelection.recentList")
    }

    private var detail: some View {
        VStack(spacing: 0) {
            Group {
                if let selectedDocument {
                    StartupSelectedDocumentView(
                        document: selectedDocument,
                        open: openRecentDocument,
                        revealInFinder: {
                            NSWorkspace.shared.activateFileViewerSelecting([selectedDocument.url])
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "作品を選んでください",
                        systemImage: "books.vertical",
                        description: Text("新しい作品を作るか、保存済みの作品を開けます。")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 10) {
                if context.recentDocument == nil {
                    newDocumentButton
                        .buttonStyle(.borderedProminent)
                } else {
                    newDocumentButton
                        .buttonStyle(.bordered)
                }

                Button {
                    documentPanelPresenter.presentOpenPanel(
                        expectedSession: appState.documentSessionToken
                    )
                } label: {
                    Label("別の作品を開く…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("startup.documentSelection.openOther")

                Spacer()
            }
            .padding(20)
        }
        .background(.background)
    }

    private var newDocumentButton: some View {
        Button {
            documentPanelPresenter.presentNewDocument(
                expectedSession: appState.documentSessionToken
            )
        } label: {
            Label("新規作品", systemImage: "doc.badge.plus")
        }
        .accessibilityIdentifier("startup.documentSelection.new")
    }

    private var selectedDocument: StartupRecentDocument? {
        guard let recentDocument = context.recentDocument,
              selectedDocumentID == recentDocument.id else { return nil }
        return recentDocument
    }

    private func openRecentDocument() {
        let session = appState.documentSessionToken
        Task {
            _ = await appState.openRecentDocument(expectedSession: session)
        }
    }
}

private struct StartupRecentDocumentRow: View {
    let document: StartupRecentDocument

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(document.displayName)
                    .lineLimit(1)

                Text(document.locationDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(document.displayName)
        .accessibilityValue("前回開いた作品、保存場所 \(document.locationDescription)")
        .accessibilityHint("選択して、作品を開くボタンで開きます。")
    }
}

private struct StartupSelectedDocumentView: View {
    let document: StartupRecentDocument
    let open: () -> Void
    let revealInFinder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "book.closed.fill")
                    .font(.largeTitle.weight(.light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(document.displayName)
                        .font(.title.weight(.semibold))
                        .lineLimit(2)

                    Text("前回開いていた作品")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            LabeledContent("保存場所") {
                Text(document.locationDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(document.url.path)
            }

            Spacer()

            HStack(spacing: 10) {
                Button("作品を開く", action: open)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("startup.documentSelection.openRecent")

                Button("Finderで表示", action: revealInFinder)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("startup.documentSelection.revealRecent")
            }
        }
        .padding(32)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
                if context.reason != .protectedLocationInDebugBuild,
                   context.reason != .deviceSyncSafetyUnavailable {
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

                if context.reason != .deviceSyncSafetyUnavailable {
                    Button("別の作品を開く…") {
                        documentPanelPresenter.presentOpenPanel()
                    }

                    Button("新規作品を作る…") {
                        newDocumentSession = appState.documentSessionToken
                        confirmsNewDocument = true
                    }
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
        case .deviceSyncSafetyUnavailable:
            "本文同期の安全情報を確認できません"
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
        case .deviceSyncSafetyUnavailable:
            "以前同期した作品を誤って編集しないよう停止しました。アプリを再起動しても直らない場合は、端末の空き容量とiCloud設定を確認してください。"
        }
    }
}
