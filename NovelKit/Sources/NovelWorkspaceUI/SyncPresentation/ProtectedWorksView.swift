import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

public struct ProtectedWorksView: View {
    public init(application: SyncV2Application, contextID: String,
                localCopies: [SyncV2LibraryItem] = [],
                removedCopyIDs: Set<WorkID> = [],
                recoverServer: @escaping (WorkID, SyncV2RecoveryRequest) async -> Bool,
                rescueLocal: @escaping (WorkID) async -> Bool,
                deleteLocal: @escaping (WorkID) async -> Bool,
                refreshed: @escaping () async -> Void) {
        self.application = application
        self.contextID = contextID
        self.refreshed = refreshed
        self.localCopies = localCopies
        self.removedCopyIDs = removedCopyIDs
        self.recoverServer = recoverServer
        self.rescueLocal = rescueLocal
        self.deleteLocal = deleteLocal
    }

    let application: SyncV2Application
    let contextID: String
    let refreshed: () async -> Void
    let removedCopyIDs: Set<WorkID>
    let localCopies: [SyncV2LibraryItem]
    let recoverServer: (WorkID, SyncV2RecoveryRequest) async -> Bool
    let rescueLocal: (WorkID) async -> Bool
    let deleteLocal: (WorkID) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fuminiwa.protection.pendingRecovery") private var pendingRecovery = Data()
    @State private var works: [SyncV2ProtectedWork] = []
    @State private var localRescueIDs: Set<WorkID> = []
    @State private var justRemovedCopyIDs: Set<WorkID> = []
    @State private var pendingDeletion: SyncV2ProtectedWork?
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
                Text("削除した作品を別作品として復元できます。端末のコピーは明示的に削除するまで保持します。")
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
                    Section("削除した作品") {
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
                                    Text(hasLocalCopy(work) ? "この端末にコピーあり" : "削除済み・サーバーで保管中")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let deletedAt = work.deletedAt {
                                        Text(deletedAt, format: .dateTime.year().month().day())
                                            .font(.caption)
                                        Text("保管期限まであと\(daysLeft(deletedAt))日").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.disabled(busy)
                        }
                    }
                    if let selected {
                        Section(selected.title) {
                            if hasLocalCopy(selected) {
                                Button("この端末のコピーを新しい作品として残す") { rescue(selected) }.disabled(busy)
                                Button("この端末から削除", role: .destructive) { pendingDeletion = selected }.disabled(busy)
                            }
                            if !selected.localRescue {
                                ForEach(points) { point in
                                    Button { recover(selected, point) } label: {
                                        VStack(alignment: .leading) {
                                            Text("元に戻す（別作品として復元）")
                                            Text(point.createdAt, format: .dateTime.year().month().day().hour().minute().second()).font(.caption)
                                        }
                                    }.disabled(busy)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("ゴミ箱")
            .toolbar { Button("閉じる") { dismiss() } }
        }
        .frame(minWidth: 330, minHeight: 450)
        .task(id: contextID) {
            task?.cancel()
            selected = nil; points = []; works = []
            do { works = try await trashRows(application.protectedWorks()) }
            catch {
                works = trashRows([])
                notice = "サーバーのゴミ箱を取得できませんでした。端末のコピーは保持しています。接続後に再試行してください。"
            }
        }
        .onDisappear { task?.cancel() }
        .confirmationDialog("この端末のコピーを削除しますか？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: {
                if !$0 {
                    pendingDeletion = nil
                }
            }
        ), titleVisibility: .visible) {
            Button("この端末から削除", role: .destructive) {
                if let work = pendingDeletion {
                    removeLocal(work)
                }
                pendingDeletion = nil
            }
        } message: { Text("先に新しい作品として残すこともできます。サーバーのゴミ箱は保管期限まで残ります。") }
    }

    private func hasLocalCopy(_ work: SyncV2ProtectedWork) -> Bool {
        !removedCopyIDs.union(justRemovedCopyIDs).contains(work.workID) &&
            (work.localRescue || localRescueIDs.contains(work.workID) || localCopies.contains { $0.workID == work.workID })
    }

    private func daysLeft(_ date: Date) -> Int {
        let end = Calendar.current.date(byAdding: .year, value: 1, to: date) ?? date
        return max(0, Int(ceil(end.timeIntervalSinceNow / 86400)))
    }

    private func trashRows(_ values: [SyncV2ProtectedWork]) -> [SyncV2ProtectedWork] {
        localRescueIDs = Set(values.filter(\.localRescue).map(\.workID))
        var rows = Dictionary(uniqueKeysWithValues: values.filter { !$0.localRescue && $0.deletedAt != nil }.map { ($0.workID, $0) })
        for value in values where value.localRescue && !removedCopyIDs.union(justRemovedCopyIDs).contains(value.workID) && rows[value.workID] == nil {
            rows[value.workID] = value
        }
        for local in localCopies where !removedCopyIDs.union(justRemovedCopyIDs).contains(local.workID) && rows[local.workID] == nil {
            rows[local.workID] = .init(workID: local.workID, title: local.title, deletedAt: nil, localRescue: true)
        }
        return rows.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func removeLocal(_ work: SyncV2ProtectedWork) {
        busy = true; notice = ""
        task = Task { @MainActor in
            defer { busy = false }
            guard await deleteLocal(work.workID), !Task.isCancelled else {
                notice = "削除は完了していません。端末のコピーを保持しています。"
                return
            }
            justRemovedCopyIDs.insert(work.workID)
            await refreshed()
            selected = nil; points = []
            works = await (try? application.protectedWorks()).map(trashRows) ?? works
            notice = "この端末での削除を完了しました。"
        }
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
                guard await recoverServer(work.workID, request), !Task.isCancelled else {
                    notice = "復元の完了を確認できませんでした。同じ日時を押すと、同じ復元を再確認します。"
                    return
                }
                pendingRecovery = Data()
                await refreshed()
                notice = "別の作品として復元しました。作品一覧から開けます。"
            }
        }
    }

    private func rescue(_ work: SyncV2ProtectedWork) {
        busy = true; notice = ""
        task = Task { @MainActor in
            defer { busy = false }
            do {
                guard await rescueLocal(work.workID), !Task.isCancelled else {
                    notice = "原稿を取り出せませんでした。元の端末データは保持しています。"
                    return
                }
                await refreshed()
                notice = "この端末に新しい作品を作りました。同期は作品を開いてから有効にできます。"
            }
        }
    }
}
