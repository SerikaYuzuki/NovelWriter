import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

/// Shared history row interaction. Fetching never holds the editor operation gate.
struct HistoryFetchControls: View {
    let application: SyncV2Application
    let workID: WorkID
    let snapshotID: SnapshotID?
    var progressNote: String?
    var announcesStatus = true
    var restore: (() async -> Void)?
    @State private var state: SyncV2HistoryFetchState = .paused
    @State private var available = false
    @State private var showsRestore = false
    @State private var confirmsNetwork = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if !available {
                status()
            }
            if snapshotID != nil {
                Button("復元") { showsRestore = true }
                    .accessibilityHint(available ? "選んだ版への復元を確認します" : SyncV2HistoryFetchState.restoreNotice)
            }
        }
        .sheet(isPresented: $showsRestore) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text(available ? "この版を復元しますか？" : "履歴の取得")
                    .font(.headline)
                Text(available ? "現在の内容を履歴に残してから、選んだ版へ戻します。" : SyncV2HistoryFetchState.restoreNotice)
                if available {
                    Button("復元") {
                        showsRestore = false
                        Task { await restore?() }
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(FuminiwaColor.paper.color)
                } else {
                    status(showAction: false)
                    if state != .suspended {
                        Button("今すぐ取得") { Task { await fetch() } }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(FuminiwaColor.paper.color)
                    }
                }
                Button("キャンセル", role: .cancel) { showsRestore = false }
            }
            .padding(Spacing.large)
            #if os(iOS)
                .presentationDetents([.medium, .large])
            #endif
                .confirmationDialog("古い履歴を取得しますか？", isPresented: $confirmsNetwork) {
                    Button("オンラインで取得") { Task { await fetch(confirmed: true) } }
                    Button("キャンセル", role: .cancel) {}
                } message: { Text(SyncV2HistoryFetchState.constrainedConfirmation) }
        }
        .confirmationDialog("古い履歴を取得しますか？", isPresented: Binding(
            get: { confirmsNetwork && !showsRestore },
            set: { confirmsNetwork = $0 }
        )) {
            Button("オンラインで取得") { Task { await fetch(confirmed: true) } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text(SyncV2HistoryFetchState.constrainedConfirmation) }
        .task(id: workID) {
            for await _ in await application.stateChanges() {
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
        .onChange(of: state) { _, value in
            if value != .complete, announcesStatus || showsRestore {
                AccessibilityNotification.Announcement(value.label).post()
            }
        }
        .onChange(of: available) { old, value in
            if !old, value, showsRestore {
                AccessibilityNotification.Announcement("履歴を取得しました。復元できます。").post()
            }
        }
    }

    private func status(showAction: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: Spacing.extraSmall) {
            if state != .complete {
                if state.label != state.actionLabel {
                    Text(state == .running ? progressNote ?? state.label : state.label)
                        .font(.caption)
                        .foregroundStyle(state == .validationFailed ? FuminiwaColor.warning.color : FuminiwaColor.textSecondary.color)
                        .accessibilityLabel(state.label)
                }
                if let details = state.details {
                    DisclosureGroup("詳細") { Text(details).font(.caption) }
                }
                if showAction, let action = state.actionLabel {
                    Button(action) { Task { await fetch() } }
                        .accessibilityLabel(action + "・古い履歴")
                }
            }
        }
    }

    private func refresh() async {
        let next = await (try? application.historyFetchState(workID: workID)) ?? .suspended
        let local: Bool = if let snapshotID {
            await (try? application.historySnapshotAvailability(workID: workID, snapshotID: snapshotID)) == .local
        } else {
            next == .complete
        }
        guard !Task.isCancelled else { return }
        state = next
        available = local
    }

    private func fetch(confirmed: Bool = false) async {
        do {
            let result = try await application.fetchHistoryNow(workID: workID, allowConstrained: confirmed)
            guard !Task.isCancelled else { return }
            confirmsNetwork = result == .needsNetworkConfirmation
            await refresh()
        } catch { state = .suspended }
    }
}

#if FUMINIWA_TEST_COMPOSITION
extension HistoryFetchControls {
    /// Uses the same presented sheet in isolated visual acceptance tests.
    func presentingRestoreForCapture() -> Self {
        var result = self
        result._showsRestore = State(initialValue: true)
        return result
    }
}
#endif
