import NovelSyncV2Application
import NovelUI
import NovelWorkspace
import SwiftUI

struct ExplicitSyncButton: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    let requestSync: () -> Void
    @State private var delayClock = SyncV2DelayClock()
    @State private var setup = ExplicitSyncPresentation()
    @State private var syncCompletionCount = 0

    private var status: WorkbenchSyncStatus {
        WorkbenchSyncStatus.resolve(
            saveState: workspace.saveState,
            progress: workspace.syncUIState?.remoteProgress,
            accountState: appState.snapshotSyncCurrentWorkAccountState,
            isSignedIn: appState.isSignedInToFuminiwa,
            isRequesting: workspace.isSyncInFlight
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            button(now: delayClock.now)
        }
        .onChange(of: status.tone) { oldTone, newTone in
            if oldTone != .success, newTone == .success, !reduceMotion {
                syncCompletionCount += 1
            }
        }
    }

    private func button(now: Date) -> some View {
        let pending = workspace.syncUIState?.oldestUnreceivedAt
        let delayed = SyncV2DelayNotice.isDelayed(since: pending, now: now)
        return Button(action: requestSync) {
            Label {
                Text(status.title)
            } icon: {
                syncSymbol(delayed: delayed)
            }
        }
        .help((delayed ? "未同期の変更があります・" : "") + status.title + " — " + (appState.snapshotSyncCurrentWorkAccountState == .unbound
                ? "この端末の同じ作品に保存します。同期用コピーは右クリックから作成できます。"
                : "使用中は自動で更新を確認します。クリックまたは⌘Sで今すぐ同期します。"))
        .contextMenu {
            if workspace.syncUIState?.remoteProgress == .failed(.remoteWorkDeleted) {
                Button("新しい作品としてこの端末に残す") {
                    Task { _ = await appState.cloneCurrentWorkIntoActiveAccount(rescueLocally: true) }
                }
            }
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

    @ViewBuilder
    private func syncSymbol(delayed: Bool) -> some View {
        let symbol = Image(systemName: status.systemImage)
            .foregroundStyle((delayed && status.tone == .secondary ? StatusTone.warning : status.tone).token.color)
            .symbolRenderingMode(.hierarchical)
        if reduceMotion {
            symbol
        } else if #available(macOS 15, *) {
            symbol
                .symbolEffect(.rotate, isActive: status.isSyncing)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: syncCompletionCount)
        } else {
            symbol
                .symbolEffect(.pulse, isActive: status.isSyncing)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: syncCompletionCount)
        }
    }
}

/// Window-owned state survives the native toolbar overflow menu closing.
@Observable
final class ExplicitSyncPresentation {
    var showingSetup = false
    var session: WorkspaceSessionToken?
    var account: WorkspaceAccountScope?

    @MainActor
    func requestSync(appState: AppState) {
        if appState.snapshotSyncCurrentWorkAccountState == .unbound || !appState.isSignedInToFuminiwa {
            Task { await appState.saveAndSyncCurrentWork() }
        } else if appState.workspaceModel.syncUIState?.remoteProgress == .needsChoice {
            NotificationCenter.default.post(name: .presentSnapshotSyncConflict, object: nil)
        } else if case .readyForSafeAdoption = appState.workspaceModel.syncUIState?.remoteProgress {
            Task { _ = await appState.applySnapshotSyncV2ServerVersion() }
        } else {
            Task { await appState.synchronizeSnapshotSyncV2() }
        }
    }

    @MainActor
    func requestSetup(appState: AppState) {
        session = appState.workspaceModel.documentSessionToken
        account = appState.snapshotSyncV2AccountScopeToken
        showingSetup = true
    }
}

struct ExplicitSyncSetupModifier: ViewModifier {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(AppState.self) private var appState
    @Bindable var presentation: ExplicitSyncPresentation

    func body(content: Content) -> some View {
        content
            .alert("作品を同期する", isPresented: $presentation.showingSetup) {
                if appState.canCloneCurrentWorkIntoActiveAccount {
                    Button("同期用のコピーを作成") {
                        guard presentation.session == workspace.documentSessionToken,
                              presentation.account == appState.snapshotSyncV2AccountScopeToken else { return }
                        Task { _ = await appState.cloneCurrentWorkIntoActiveAccount() }
                    }
                } else if !appState.isSignedInToFuminiwa {
                    Button("Appleでサインイン") { Task { await appState.signInWithApple() } }
                    Button("Googleでサインイン") { Task { await appState.signInWithGoogle() } }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(appState.isSignedInToFuminiwa
                    ? "この端末の原本を残して、同期用の作品をアカウントに追加します。以後は追加した作品を編集します。"
                    : "この作品は端末内に保存されています。サインイン後、もう一度「今すぐ同期」からアカウントに追加できます。")
            }
            .onChange(of: workspace.documentSessionToken) { _, _ in presentation.showingSetup = false }
            .onChange(of: appState.snapshotSyncV2AccountScopeToken) { _, _ in presentation.showingSetup = false }
    }
}
