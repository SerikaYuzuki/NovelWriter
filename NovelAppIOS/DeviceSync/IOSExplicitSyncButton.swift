import NovelSyncV2Application
import NovelUI
import NovelWorkspace
import SwiftUI

struct IOSExplicitSyncButton: View {
    let store: IOSDocumentStore
    var status: SyncV2LibraryStatus?
    @State private var delayClock = SyncV2DelayClock()
    @State private var showingSetup = false
    @State private var session: WorkspaceSessionToken?
    @State private var account: WorkspaceAccountScope?

    private var isSignedIn: Bool {
        if case .signedIn = store.authUIState {
            return true
        }
        return false
    }

    private var canAdd: Bool {
        isSignedIn && !store.isCurrentWorkParked &&
            store.syncV2LibraryItems.first(where: { $0.workID == store.syncV2ActiveWorkID })?.accountState == .unbound
    }

    var body: some View {
        Button {
            if store.snapshotSyncConflict != nil {
                store.showsConflictSheet = true
            } else if case .readyForSafeAdoption = store.snapshotSyncState?.remoteProgress {
                Task { _ = await store.adoptPendingSnapshotSyncV2() }
            } else if store.canExplicitlySyncCurrentWork {
                Task { _ = await store.synchronizeSnapshotSyncV2() }
            } else {
                session = store.currentDocumentSessionToken
                account = store.snapshotSyncV2AccountScope
                showingSetup = true
            }
        } label: {
            if case .readyForSafeAdoption = store.snapshotSyncState?.remoteProgress {
                Label("サーバーに新しい版があります", systemImage: "arrow.down.circle")
            } else if store.snapshotSyncConflict != nil {
                Label("競合の版を確認", systemImage: "exclamationmark.triangle")
            } else if let status {
                StatusLabel(status.text, systemImage: status.symbol, tone: StatusTone(rawValue: status.tone.rawValue) ?? .secondary)
            } else {
                Label(store.isSnapshotSyncInFlight ? "同期中…" : "今すぐ同期", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .accessibilityHint(status == nil ? "" : "タップして同期します")
        .disabled(store.isSnapshotSyncInFlight || store.isDocumentTransitionInProgress || store.isSyncV2RemoteAccountTransitionActive || store.syncV2AccountCloneInFlight)
        .accessibilityIdentifier("ios.editor.sync")
        .contextMenu {
            if store.snapshotSyncState?.remoteProgress == .failed(.remoteWorkDeleted) {
                Button("新しい作品としてこの端末に残す") {
                    Task { _ = await store.cloneActiveWorkIntoSignedInAccount(rescueLocally: true) }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                if SyncV2DelayNotice.isDelayed(since: store.snapshotSyncState?.oldestUnreceivedAt, now: delayClock.now) {
                    Circle().fill(FuminiwaColor.warning.color).frame(width: 6, height: 6)
                        .accessibilityLabel("未同期の変更があります")
                }
            }
        }
        .confirmationDialog("作品を同期する", isPresented: $showingSetup, titleVisibility: .visible) {
            if canAdd {
                Button("アカウントへ追加して同期") {
                    guard session == store.currentDocumentSessionToken,
                          account == store.snapshotSyncV2AccountScope else { return }
                    Task { _ = await store.cloneActiveWorkIntoSignedInAccount() }
                }
            } else if !isSignedIn {
                Button("Appleでサインイン") { Task { await store.signInWithApple() } }
                Button("Googleでサインイン") { Task { await store.signInWithGoogle() } }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(store.isCurrentWorkParked
                ? "別のアカウントに属する作品です。元のアカウントでサインインしてください。"
                : canAdd
                ? "この端末の原本を残して、同期用の作品をアカウントに追加します。"
                : "サインイン後、もう一度「今すぐ同期」から作品をアカウントに追加できます。")
        }
        .onChange(of: store.currentDocumentSessionToken) { _, _ in showingSetup = false }
        .onChange(of: store.snapshotSyncV2AccountScope) { _, _ in showingSetup = false }
    }
}
