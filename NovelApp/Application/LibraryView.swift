import NovelUI
import SwiftUI

/// The library and editor share the workbench scene and its document lifecycle.
struct LibraryView: View {
    var observesLibrary = true
    @Environment(AppState.self) private var appState

    var body: some View {
        LibraryPane(observesImports: observesLibrary)
            .frame(minWidth: 700, minHeight: 480)
            .navigationTitle("ふみにわ")
            .task {
                guard observesLibrary else { return }
                await appState.refreshSnapshotLibrary()
                await appState.refreshSnapshotRemoteCatalog()
            }
    }
}

struct LibraryCommand: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button("作品一覧…") {
            Task { await appState.returnToSnapshotLibrary() }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(!appState.permitsDocumentTransitionOperation)
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
                ProgressView("サインイン中…").controlSize(.small)
            case .signedOut, .failed, .unavailable:
                Button("Appleでサインイン") { Task { await appState.signInWithApple() } }
                Button("Googleでサインイン") { Task { await appState.signInWithGoogle() } }
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
    static let focusLibrarySearch = Notification.Name("fuminiwa.focusLibrarySearch")
    static let toggleWritingAssistant = Notification.Name("fuminiwa.toggleWritingAssistant")
}
