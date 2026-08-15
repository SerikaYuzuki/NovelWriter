import SwiftUI

struct IOSWorkSaveStatusButton: View {
    let store: IOSDocumentStore
    let accessibilityIdentifier: String
    var isNoteSyncConflictPresented: Binding<Bool>
    @Binding var isDeviceSyncConflictPresented: Bool

    var body: some View {
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
        .labelStyle(.iconOnly)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct IOSWorkExplicitSyncButton: View {
    let store: IOSDocumentStore
    let accessibilityIdentifier: String

    var body: some View {
        Button {
            Task { await store.saveAndSyncNow() }
        } label: {
            Label("iCloudと同期", systemImage: "arrow.clockwise.icloud")
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
