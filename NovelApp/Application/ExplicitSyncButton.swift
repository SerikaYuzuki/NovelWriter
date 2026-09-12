import NovelSyncV2Application
import SwiftUI

struct ExplicitSyncButton: View {
    @Environment(AppState.self) private var appState
    let requestSync: () -> Void
    @State private var setup = ExplicitSyncPresentation()

    private var status: WorkbenchSyncStatus {
        WorkbenchSyncStatus.resolve(
            saveState: appState.saveState,
            progress: appState.snapshotSyncV2UIState?.remoteProgress,
            accountState: appState.snapshotSyncCurrentWorkAccountState,
            isSignedIn: appState.isSignedInToFuminiwa,
            isRequesting: appState.isSnapshotSyncInFlight
        )
    }

    var body: some View {
        Button(action: requestSync) {
            HStack(spacing: 5) {
                Image(systemName: status.systemImage)
                Text(status.title)
            }
            .fixedSize()
            .foregroundStyle(status.isWarning ? Color.orange : Color.primary)
        }
        .help(appState.snapshotSyncCurrentWorkAccountState == .unbound
            ? "この端末の同じ作品に保存します。同期用コピーは右クリックから作成できます。"
            : "クリックまたは⌘Sで保存して同期します。")
        .contextMenu {
            if appState.canCloneCurrentWorkIntoActiveAccount {
                Button("同期用のコピーを作成…") { setup.requestSetup(appState: appState) }
            } else if !appState.isSignedInToFuminiwa {
                Button("同期の設定…") { setup.requestSetup(appState: appState) }
            }
        }
        .modifier(ExplicitSyncSetupModifier(presentation: setup))
        .accessibilityLabel(appState.snapshotSyncCurrentWorkAccountState == .unbound ? "\(status.title)、この端末に保存" : "\(status.title)、今すぐ同期")
        .disabled(!appState.canExplicitlySyncCurrentWork)
        .accessibilityIdentifier("workbench.snapshot.sync")
    }
}

/// Window-owned state survives the native toolbar overflow menu closing.
@Observable
final class ExplicitSyncPresentation {
    var showingSetup = false
    var session: AppDocumentSessionToken?
    var account: SnapshotSyncV2AccountScopeToken?

    @MainActor
    func requestSync(appState: AppState) {
        if appState.snapshotSyncCurrentWorkAccountState == .unbound || !appState.isSignedInToFuminiwa {
            Task { await appState.saveAndSyncCurrentWork() }
        } else if appState.snapshotSyncV2UIState?.remoteProgress == .needsChoice {
            NotificationCenter.default.post(name: .presentSnapshotSyncConflict, object: nil)
        } else if case .readyForSafeAdoption = appState.snapshotSyncV2UIState?.remoteProgress {
            Task { _ = await appState.applySnapshotSyncV2ServerVersion() }
        } else {
            Task { await appState.synchronizeSnapshotSyncV2() }
        }
    }

    @MainActor
    func requestSetup(appState: AppState) {
        session = appState.documentSessionToken
        account = appState.snapshotSyncV2AccountScopeToken
        showingSetup = true
    }
}

struct ExplicitSyncSetupModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Bindable var presentation: ExplicitSyncPresentation

    func body(content: Content) -> some View {
        content
            .alert("作品を同期する", isPresented: $presentation.showingSetup) {
                if appState.canCloneCurrentWorkIntoActiveAccount {
                    Button("同期用のコピーを作成") {
                        guard presentation.session == appState.documentSessionToken,
                              presentation.account == appState.snapshotSyncV2AccountScopeToken else { return }
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
            .onChange(of: appState.documentSessionToken) { _, _ in presentation.showingSetup = false }
            .onChange(of: appState.snapshotSyncV2AccountScopeToken) { _, _ in presentation.showingSetup = false }
    }
}
