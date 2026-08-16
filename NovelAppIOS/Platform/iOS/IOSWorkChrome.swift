import NovelLocalStore
import SwiftUI

struct IOSWorkSaveStatusButton: View {
    let store: IOSDocumentStore
    let accessibilityIdentifier: String
    var isNoteSyncConflictPresented: Binding<Bool>
    @Binding var isDeviceSyncConflictPresented: Bool

    var body: some View {
        Group {
            if store.usesSnapshotSyncRuntime {
                IOSSnapshotSyncStatusControl(
                    saveState: store.saveState,
                    outcome: store.snapshotSyncOutcome
                )
            } else {
                IOSDeviceSyncStatusControl(
                    saveState: store.saveState,
                    state: store.deviceSyncState,
                    transferState: store.deviceSyncTransferState,
                    localDurabilityState: store.deviceSyncLocalDurabilityState,
                    hasLocalRecoveryReview: store.deviceSyncLocalRecoveryReview != nil
                        || store.workSyncLocalRecoveryReview != nil
                        || store.workSyncConflictReview != nil
                        || store.noteSyncConflict != nil,
                    isLocalRecoveryReviewReady: store.workSyncLocalRecoveryReview != nil
                        || !store.deviceSyncLocalRecoveryPending,
                    usesWholeWorkSync: store.usesWholeWorkDeviceSync
                ) {
                    if store.noteSyncConflict != nil {
                        isNoteSyncConflictPresented.wrappedValue = true
                        return
                    }
                    guard store.workSyncLocalRecoveryReview != nil
                        || store.workSyncConflictReview != nil
                        || store.deviceSyncConflict != nil
                        || store.deviceSyncLocalRecoveryReview != nil else { return }
                    isDeviceSyncConflictPresented = true
                }
            }
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct IOSSnapshotSyncStatusControl: View {
    let saveState: IOSSaveState
    let outcome: SnapshotSyncOutcome
    @State private var showsDetails = false

    private var title: String {
        if saveState != .saved {
            return "この端末へ保存中"
        }
        switch outcome {
        case .notStarted: return "同期状態を未確認"
        case .uploaded: return "この端末とサーバーに同期済み"
        case .idle: return "変更なし、同期済み"
        case .offline: return "この端末に保存済み、同期待ち"
        case .needsChoice: return "同期を停止しました、確認が必要"
        }
    }

    private var detail: String {
        if saveState != .saved {
            return "変更内容をこの端末へ保存しています。入力はそのまま続けられます。"
        }
        switch outcome {
        case .notStarted:
            return "変更内容はこの端末に保存されています。サーバーとの状態はまだ確認していません。"
        case .uploaded:
            return "変更内容はこの端末とサーバーに保存されています。"
        case .idle:
            return "変更はありません。現在の内容はこの端末とサーバーで一致しています。"
        case .offline:
            return "変更内容はこの端末に保存されています。接続が戻ると自動で同期します。"
        case .needsChoice:
            return "この端末の版は保持されています。サーバーの版と比較して、残す版を選ぶ必要があります。"
        }
    }

    private var systemImage: String {
        if saveState != .saved {
            return "arrow.triangle.2.circlepath"
        }
        switch outcome {
        case .notStarted: return "questionmark.circle"
        case .uploaded, .idle: return "checkmark.circle"
        case .offline: return "wifi.slash"
        case .needsChoice: return "exclamationmark.triangle"
        }
    }

    private var isWarning: Bool {
        if case .needsChoice = outcome {
            return true
        }
        return false
    }

    var body: some View {
        Button { showsDetails = true } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isWarning ? .orange : .secondary)
        .accessibilityLabel(title)
        .accessibilityHint("保存と同期の詳細を表示します")
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 300, alignment: .leading)
        }
    }
}

struct IOSWorkExplicitSyncButton: View {
    let store: IOSDocumentStore
    let accessibilityIdentifier: String

    var body: some View {
        Button {
            Task { await store.saveAndSyncNow() }
        } label: {
            Label("サーバーと同期", systemImage: "arrow.clockwise")
        }
        .disabled(store.isExplicitNoteSyncInFlight)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct IOSWorkChromeToolbarContent: ToolbarContent {
    let store: IOSDocumentStore
    let accessibilityPrefix: String
    var isNoteSyncConflictPresented: Binding<Bool>
    @Binding var isSnapshotPresented: Bool
    @Binding var isDeviceSyncConflictPresented: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            IOSWorkSaveStatusButton(
                store: store,
                accessibilityIdentifier: "\(accessibilityPrefix).saveState",
                isNoteSyncConflictPresented: isNoteSyncConflictPresented,
                isDeviceSyncConflictPresented: $isDeviceSyncConflictPresented
            )
            if store.canExplicitlySyncCurrentWork {
                IOSWorkExplicitSyncButton(
                    store: store,
                    accessibilityIdentifier: "\(accessibilityPrefix).sync"
                )
            }
            IOSSnapshotToolbarButton(
                accessibilityIdentifier: "\(accessibilityPrefix).snapshot",
                isPresented: $isSnapshotPresented
            )
        }
    }
}

private struct IOSWorkChromeModifier: ViewModifier {
    let store: IOSDocumentStore
    let accessibilityPrefix: String
    @Environment(\.iosNoteSyncConflictPresented) private var isNoteSyncConflictPresented
    @State private var isSnapshotPresented = false
    @State private var isDeviceSyncConflictPresented = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                IOSWorkChromeToolbarContent(
                    store: store,
                    accessibilityPrefix: accessibilityPrefix,
                    isNoteSyncConflictPresented: isNoteSyncConflictPresented,
                    isSnapshotPresented: $isSnapshotPresented,
                    isDeviceSyncConflictPresented: $isDeviceSyncConflictPresented
                )
            }
            .iosSnapshotSheet(store: store, isPresented: $isSnapshotPresented)
            .iosEditorLegacySyncSheets(store: store, isPresented: $isDeviceSyncConflictPresented)
    }
}

extension View {
    func iosWorkChrome(store: IOSDocumentStore, accessibilityPrefix: String) -> some View {
        modifier(
            IOSWorkChromeModifier(store: store, accessibilityPrefix: accessibilityPrefix)
        )
    }
}
