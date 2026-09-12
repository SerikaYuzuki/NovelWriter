import SwiftUI

struct ExplicitSyncButton: View {
    @Environment(AppState.self) private var appState
    @State private var showingSetup = false
    @State private var session: AppDocumentSessionToken?
    @State private var account: SnapshotSyncV2AccountScopeToken?

    var body: some View {
        Button {
            if !appState.isSignedInToFuminiwa || appState.canCloneCurrentWorkIntoActiveAccount {
                session = appState.documentSessionToken
                account = appState.snapshotSyncV2AccountScopeToken
                showingSetup = true
            } else {
                Task { await appState.synchronizeSnapshotSyncV2() }
            }
        } label: {
            Label(appState.isSnapshotSyncInFlight ? "同期中…" : "今すぐ同期", systemImage: "arrow.triangle.2.circlepath")
                .labelStyle(.titleAndIcon)
        }
        .help("入力を確定して端末に保存し、サーバーと同期します")
        .disabled(!appState.canExplicitlySyncCurrentWork)
        .accessibilityIdentifier("workbench.snapshot.sync")
        .confirmationDialog("作品を同期する", isPresented: $showingSetup, titleVisibility: .visible) {
            if appState.canCloneCurrentWorkIntoActiveAccount {
                Button("アカウントへ追加して同期") {
                    guard session == appState.documentSessionToken,
                          account == appState.snapshotSyncV2AccountScopeToken else { return }
                    Task { _ = await appState.cloneCurrentWorkIntoActiveAccount() }
                }
            } else if !appState.isSignedInToFuminiwa {
                Button("Appleでサインイン") { Task { await appState.signInWithApple() } }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(appState.isSignedInToFuminiwa
                ? "この端末の原本を残して、同期用の作品をアカウントに追加します。以後は追加した作品を編集します。"
                : "この作品は端末内に保存されています。サインイン後、もう一度「今すぐ同期」からアカウントに追加できます。")
        }
        .onChange(of: appState.documentSessionToken) { _, _ in showingSetup = false }
        .onChange(of: appState.snapshotSyncV2AccountScopeToken) { _, _ in showingSetup = false }
    }
}
