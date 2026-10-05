import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

public struct SnapshotRestoreComparison: View {
    public init(application: SyncV2Application, workID: WorkID, snapshotID: SnapshotID) {
        self.application = application
        self.workID = workID
        self.snapshotID = snapshotID
    }

    let application: SyncV2Application
    let workID: WorkID
    let snapshotID: SnapshotID
    @State private var difference: SnapshotDifference?
    @State private var failed = false
    @State private var showsPreview = false

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("現在の版との違い").font(.caption).foregroundStyle(.secondary)
            Text(difference?.line ?? (failed ? "内容を確認できません" : "確認中…"))
                .font(FuminiwaType.rowSecondary)
            Button("中身を見る") { showsPreview = true }
                .disabled(difference?.available != true)
                .buttonStyle(.bordered)
        }
        .task(id: snapshotID) {
            for await _ in await application.stateChanges(for: workID) {
                guard !Task.isCancelled else { return }
                do {
                    if let current = try await application.currentSnapshotID(workID: workID) {
                        let value = try await application.snapshotDifference(workID: workID, before: current, after: snapshotID)
                        guard !Task.isCancelled else { return }
                        difference = value
                    }
                } catch { failed = true }
            }
        }
        .sheet(isPresented: $showsPreview) {
            if let difference {
                SnapshotDifferencePreview(application: application, workID: workID, snapshotID: snapshotID, difference: difference)
            }
        }
    }
}
