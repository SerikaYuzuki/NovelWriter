import SwiftUI

struct LibraryWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var presenter

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 48)).foregroundStyle(.tint)
                Text("ふみにわ").font(.largeTitle.bold())
                Text("書きたい物語を、ここから。")
                    .foregroundStyle(.secondary)
                Button("新しい作品…") { presenter.presentNewDocument() }
                Button("作品を取り込む…") { presenter.presentOpenPanel() }
                Spacer()
                Text("オフラインでも作成・編集できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28).frame(width: 280)
            Divider()
            LibraryPane()
                .padding(.vertical, 16)
        }
        .frame(minWidth: 700, minHeight: 420)
        .onChange(of: presenter.completedDocumentOperation) { _, _ in
            openWindow(id: "workbench")
        }
        .task {
            await appState.refreshSnapshotLibrary()
            await appState.refreshSnapshotRemoteCatalog()
        }
        .alert("作品の操作", isPresented: Binding(
            get: { appState.operationMessage != nil || presenter.alertMessage != nil },
            set: {
                if !$0 {
                    appState.dismissOperationMessage()
                    presenter.alertMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { appState.dismissOperationMessage() }
        } message: { Text(presenter.alertMessage ?? appState.operationMessage ?? "") }
    }
}

struct LibraryWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("作品一覧…") { openWindow(id: "library") }
            .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

struct AccountAccessView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch appState.authUIState {
            case .signedIn:
                Menu {
                    Button("サインアウト") { Task { await appState.signOutFromFuminiwa() } }
                } label: { Label("サインイン済み", systemImage: "person.crop.circle.badge.checkmark") }
            case .signingIn:
                ProgressView("Appleでサインイン中…").controlSize(.small)
            case .signedOut, .failed, .unavailable:
                Button("Appleでサインイン") { Task { await appState.signInWithApple() } }
                    .disabled(appState.authUIState == .unavailable)
                if case .failed = appState.authUIState {
                    Text("サインインできませんでした。再試行できます。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if appState.authUIState == .unavailable {
                    Text("同期サーバーが未設定です。端末内で利用できます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension Notification.Name {
    static let toggleWritingAssistant = Notification.Name("fuminiwa.toggleWritingAssistant")
}
