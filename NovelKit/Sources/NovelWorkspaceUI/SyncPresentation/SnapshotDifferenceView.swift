import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

public struct SnapshotDifferenceLine: View {
    public init(application: SyncV2Application, workID: WorkID, before: SnapshotID?, after: SnapshotID) {
        self.application = application
        self.workID = workID
        self.before = before
        self.after = after
    }

    let application: SyncV2Application
    let workID: WorkID
    let before: SnapshotID?
    let after: SnapshotID
    @State private var line = "確認中…"

    public var body: some View {
        Text(line).font(FuminiwaType.rowSecondary).lineLimit(1)
            .foregroundStyle(FuminiwaColor.textSecondary.color)
            .task(id: SnapshotDifferenceTaskID(workID: workID, before: before, after: after)) {
                for await event in await application.stateChanges(for: workID) {
                    guard !Task.isCancelled else { return }
                    guard event.concerns(workID) else { continue }
                    await load()
                }
            }
    }

    private func load() async {
        guard let before else {
            let hasParents = try? await application.snapshotHasParents(workID: workID, snapshotID: after)
            guard !Task.isCancelled else { return }
            line = hasParents == false ? "比較する前の版はありません" : "未取得"
            return
        }
        do {
            let difference = try await application.snapshotDifference(workID: workID, before: before, after: after)
            guard !Task.isCancelled else { return }
            line = difference.line
        } catch {
            guard !Task.isCancelled else { return }
            line = "内容を確認できません"
        }
    }
}

private struct SnapshotDifferenceTaskID: Hashable {
    let workID: WorkID
    let before: SnapshotID?
    let after: SnapshotID
}

/// Preview navigation reads the selected immutable body only when it is opened.
public struct SnapshotDifferencePreview: View {
    public init(application: SyncV2Application, workID: WorkID, snapshotID: SnapshotID, difference: SnapshotDifference) {
        self.application = application
        self.workID = workID
        self.snapshotID = snapshotID
        self.difference = difference
    }

    let application: SyncV2Application
    let workID: WorkID
    let snapshotID: SnapshotID
    let difference: SnapshotDifference
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            List(difference.episodes) { episode in
                NavigationLink {
                    SnapshotEpisodePreview(application: application, workID: workID, snapshotID: snapshotID, episode: episode)
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                        Text(episode.heading)
                        Text("\(episode.afterCount)字").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if difference.episodes.isEmpty {
                    ContentUnavailableView("本文の変更はありません", systemImage: "doc.text",
                                           description: Text(difference.line))
                }
            }
            .navigationTitle("変わった話")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 400)
        #endif
    }
}

public struct SnapshotEpisodePreview: View {
    public init(application: SyncV2Application, workID: WorkID, snapshotID: SnapshotID, episodeID: String, heading: String) {
        self.application = application
        self.workID = workID
        self.snapshotID = snapshotID
        self.episodeID = episodeID
        self.heading = heading
    }

    init(application: SyncV2Application, workID: WorkID, snapshotID: SnapshotID, episode: SnapshotEpisodeDifference) {
        self.init(application: application, workID: workID, snapshotID: snapshotID, episodeID: episode.id, heading: episode.heading)
    }

    let application: SyncV2Application
    let workID: WorkID
    let snapshotID: SnapshotID
    let episodeID: String
    let heading: String
    @State private var bodyText: String?
    @State private var failed = false

    public var body: some View {
        ScrollView {
            if let bodyText {
                Text(bodyText.isEmpty ? "本文は空です" : bodyText)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.outer)
            } else if failed {
                Text("本文を確認できません").padding(Spacing.outer)
            } else {
                ProgressView("本文を読み込んでいます…").padding(Spacing.outer)
            }
        }
        .navigationTitle(heading)
        .task {
            do {
                let value = try await application.snapshotEpisodePreview(workID: workID, snapshotID: snapshotID, episodeID: episodeID)
                guard !Task.isCancelled else { return }
                bodyText = value
            } catch { failed = true }
        }
    }
}
