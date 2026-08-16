import NovelCore
import SwiftUI

struct IOSSnapshotToolbarButton: View {
    let accessibilityIdentifier: String
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("スナップショット", systemImage: "clock.arrow.circlepath")
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct IOSSnapshotSheet: View {
    let store: IOSDocumentStore
    let session: IOSDocumentSessionToken
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [DocumentSnapshotInfo] = []
    @State private var pendingRestore: DocumentSnapshotInfo?

    var body: some View {
        NavigationStack {
            snapshotList
                .navigationTitle("スナップショット")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    snapshotToolbar
                }
                .task {
                    await refresh()
                }
                .alert(
                    "このスナップショットに戻しますか？",
                    isPresented: restoreAlertIsPresented
                ) {
                    restoreAlertButtons
                } message: {
                    Text(restoreMessage)
                }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("ios.snapshot.sheet")
    }

    @ViewBuilder
    private var snapshotList: some View {
        if snapshots.isEmpty {
            ContentUnavailableView {
                Label("スナップショットがありません", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("保存ボタンから、または編集のあと約5分で現在の状態を記録できます。スナップショットは原稿の同期とは別に復元できます。")
            } actions: {
                Button("保存") {
                    Task { await saveSnapshot() }
                }
                .accessibilityIdentifier("ios.snapshot.save.empty")
            }
        } else {
            List(snapshots) { item in
                Button(item.displayName) {
                    pendingRestore = item
                }
                .accessibilityIdentifier("ios.snapshot.item")
            }
            .listStyle(.plain)
        }
    }

    @ToolbarContentBuilder
    private var snapshotToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("閉じる") {
                dismiss()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await saveSnapshot() }
            } label: {
                Label("保存", systemImage: "plus")
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .accessibilityIdentifier("ios.snapshot.save")
        }
    }

    @ViewBuilder
    private var restoreAlertButtons: some View {
        Button("復元") {
            guard let pendingRestore else { return }
            let target = pendingRestore
            self.pendingRestore = nil
            Task {
                let restored = await store.restoreSnapshot(
                    at: target.url,
                    expectedSession: session
                )
                if restored {
                    dismiss()
                } else {
                    await refresh()
                }
            }
        }
        Button("キャンセル", role: .cancel) {
            pendingRestore = nil
        }
    }

    private var restoreMessage: String {
        "「\(pendingRestore?.displayName ?? "")」の状態に戻します。いまの内容は先にスナップショットへ退避します。"
    }

    private var restoreAlertIsPresented: Binding<Bool> {
        Binding(
            get: { pendingRestore != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRestore = nil
                }
            }
        )
    }

    private func saveSnapshot() async {
        _ = await store.createSnapshot(expectedSession: session)
        await refresh()
    }

    private func refresh() async {
        guard store.currentDocumentSessionToken == session else { return }
        snapshots = await store.listSnapshots(expectedSession: session)
    }
}

extension View {
    func iosSnapshotSheet(
        store: IOSDocumentStore,
        isPresented: Binding<Bool>
    ) -> some View {
        sheet(isPresented: isPresented) {
            if let session = store.currentDocumentSessionToken {
                IOSSnapshotSheet(store: store, session: session)
            }
        }
    }
}
