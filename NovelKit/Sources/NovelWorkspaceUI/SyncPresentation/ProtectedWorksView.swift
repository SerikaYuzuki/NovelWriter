import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

public struct ProtectedWorksView: View {
    public init(application: SyncV2Application, contextID: String, refreshed: @escaping () async -> Void) {
        self.application = application
        self.contextID = contextID
        self.refreshed = refreshed
    }

    let application: SyncV2Application
    let contextID: String
    let refreshed: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fuminiwa.protection.pendingRecovery") private var pendingRecovery = Data()
    @State private var works: [SyncV2ProtectedWork] = []
    @State private var selected: SyncV2ProtectedWork?
    @State private var points: [SyncV2RecoveryPoint] = []
    @State private var notice = ""
    @State private var busy = false
    @State private var task: Task<Void, Never>?

    private struct Attempt: Codable {
        let source: String
        let request: SyncV2RecoveryRequest
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("選んだ内容を新しい作品として取り出します。元の作品は残ります。")
                    .font(.subheadline)
                Text("直近7日間は各受領時点、それより前は1日ごと。削除した作品は削除日から1年間保管します。")
                    .font(.caption).foregroundStyle(.secondary)
                if busy {
                    ProgressView().controlSize(.small)
                }
                if !notice.isEmpty {
                    Text(notice).font(.caption).textSelection(.enabled)
                }
                List {
                    Section("保管している作品") {
                        ForEach(works) { work in
                            Button {
                                selected = work
                                points = []
                                if !work.localRescue {
                                    loadPoints(work)
                                }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(work.title.isEmpty ? "名称未設定の作品" : work.title)
                                    Text(work.localRescue ? "この端末の削除時の原稿（未送信の変更を含む）"
                                        : work.deletedAt == nil ? "サーバーの受領済み履歴" : "削除済み・サーバーで保管中")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(busy)
                        }
                    }
                    if let selected {
                        Section(selected.title) {
                            if selected.localRescue {
                                Button("新しい作品としてこの端末に残す") { rescue(selected) }.disabled(busy)
                            } else {
                                ForEach(points) { point in
                                    Button { recover(selected, point) } label: {
                                        Text(point.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                                    }.disabled(busy)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("作品を復元")
            .toolbar { Button("閉じる") { dismiss() } }
        }
        .frame(minWidth: 330, minHeight: 450)
        .task(id: contextID) {
            task?.cancel()
            selected = nil; points = []; works = []
            do { works = try await application.protectedWorks() }
            catch { notice = "保管内容を取得できませんでした。サインインと接続を確認してください。" }
        }
        .onDisappear { task?.cancel() }
    }

    private func loadPoints(_ work: SyncV2ProtectedWork) {
        busy = true; notice = ""
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let values = try await application.recoveryPoints(workID: work.workID)
                guard !Task.isCancelled, selected?.id == work.id else { return }
                points = values
                if points.isEmpty {
                    notice = "受領済みの復元点がありません。"
                }
            } catch { notice = "履歴を取得できませんでした。接続後に選び直してください。" }
        }
    }

    private func recover(_ work: SyncV2ProtectedWork, _ point: SyncV2RecoveryPoint) {
        let previous = try? JSONDecoder().decode(Attempt.self, from: pendingRecovery)
        let request = if previous?.source == work.workID.description,
                         previous?.request.snapshotId == point.snapshotID.rawValue {
            previous!.request
        } else {
            SyncV2RecoveryRequest(snapshotID: point.snapshotID)
        }
        do { pendingRecovery = try JSONEncoder().encode(Attempt(source: work.workID.description, request: request)) }
        catch { notice = "復元の準備を保存できませんでした。"; return }
        busy = true; notice = ""
        task = Task { @MainActor in
            defer { busy = false }
            do {
                try await application.recoverWork(workID: work.workID, request: request)
                guard !Task.isCancelled else { return }
                pendingRecovery = Data()
                await refreshed()
                notice = "別の作品として復元しました。作品一覧から開けます。"
            } catch { notice = "復元の完了を確認できませんでした。同じ日時を押すと、同じ復元を再確認します。" }
        }
    }

    private func rescue(_ work: SyncV2ProtectedWork) {
        busy = true; notice = ""
        task = Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await application.rescueLocalWork(sourceWorkID: work.workID)
                guard !Task.isCancelled else { return }
                await refreshed()
                notice = "この端末に新しい作品を作りました。同期は作品を開いてから有効にできます。"
            } catch { notice = "原稿を取り出せませんでした。元の端末データは保持しています。" }
        }
    }
}
