import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import NovelWorkspace
import SwiftUI

/// One shared list and restore interaction for the Mac popover and iOS sheet.
public struct EpisodeHistoryList: View {
    public init(application: SyncV2Application, workID: WorkID, chapterID: ChapterID, episodeID: EpisodeID,
                heading: String, scope: String, userDefaults: UserDefaults,
                currentBody: @escaping () -> String?, host: @escaping () -> WorkReplacementHost,
                wholeWorkHistory: @escaping () -> Void) {
        self.application = application
        self.workID = workID
        self.chapterID = chapterID
        self.episodeID = episodeID
        self.heading = heading
        self.scope = scope
        self.userDefaults = userDefaults
        self.currentBody = currentBody
        self.host = host
        self.wholeWorkHistory = wholeWorkHistory
        _deviceLabelOverride = AppStorage(wrappedValue: "", DeviceLabel.defaultsKey, store: userDefaults)
    }

    let application: SyncV2Application
    let workID: WorkID
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let heading: String
    let scope: String
    let userDefaults: UserDefaults
    let currentBody: () -> String?
    let host: () -> WorkReplacementHost
    let wholeWorkHistory: () -> Void
    @AppStorage private var deviceLabelOverride: String
    @State private var loadRevision = UUID()
    @State private var loadTask: Task<Void, Never>?
    @State private var loadingOlder = false
    @State private var isVisible = false
    @State private var history = EpisodeHistory()
    @State private var loaded = false
    @State private var loadError: String?
    @State private var preparing = false
    @State private var request: EpisodeRestoreRequest?
    @State private var preview: EpisodeHistoryVersion?
    @State private var restore = EpisodeRestoreSession()

    public var body: some View {
        let bodyText = currentBody()
        let currentObjectID = bodyText.map { SnapshotCodec.episodeBodyObjectID($0) }
        let canRestore = host().validate() && bodyText != nil
        List {
            Section {
                Button("作品全体の履歴…", action: wholeWorkHistory)
                if host().document().episode(episodeID) == nil {
                    Text("この話は現在の作品にありません。作品全体の履歴から復元してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = restore.message {
                    Text(message).font(.caption)
                }
            } header: { Text(heading + "の履歴") }
            if !loaded {
                ProgressView("履歴を読み込んでいます…")
            }
            if loaded, !loadingOlder, history.versions.isEmpty, loadError == nil {
                Text("この話の本文が変わった履歴はありません。")
                    .foregroundStyle(.secondary)
            }
            let versions = Dictionary(uniqueKeysWithValues: history.versions.map { ($0.id, $0) })
            let presentation = HistoryPresentation()
            ForEach(presentation.days(history.versions.map(\.item))) { day in
                Section(day.title) {
                    ForEach(day.runs) { run in
                        if run.isCollapsedAutosave,
                           let newest = versions[run.items[0].occurrenceID],
                           let oldest = run.items.last.flatMap({ versions[$0.occurrenceID] }) {
                            DisclosureGroup {
                                ForEach(run.items, id: \.occurrenceID) { item in
                                    if let version = versions[item.occurrenceID] {
                                        row(version, currentObjectID: currentObjectID, canRestore: canRestore)
                                    }
                                }
                            } label: {
                                let occurrences = run.items.flatMap { versions[$0.occurrenceID]?.occurrences ?? [] }
                                VStack(alignment: .leading) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(presentation.time(newest.item.createdAt)).monospacedDigit()
                                        EpisodeHistoryMetrics(application: application, workID: workID, episodeID: episodeID,
                                                              reference: newest.body, previous: oldest.previous, currentObjectID: currentObjectID)
                                    }
                                    Text(presentation.autosaveLabel(.init(items: occurrences)) + " · " + deviceLabel(newest.item))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else if let version = versions[run.items[0].occurrenceID] {
                            row(version, currentObjectID: currentObjectID, canRestore: canRestore)
                        }
                    }
                }
            }
            if loadingOlder {
                ProgressView("古い履歴を読み込み中…")
            }
            if history.unfetchedCount > 0 {
                Section {
                    Text("未取得の履歴 \(history.unfetchedCount)件").font(.subheadline)
                    Text("取得すると、この話の本文が変わった版を表示します。")
                        .font(.caption).foregroundStyle(.secondary)
                    HistoryFetchControls(application: application, workID: workID, snapshotID: nil,
                                         userDefaults: userDefaults)
                }
            }
            if history.onlineFailure != nil {
                Text("オンラインの履歴を取得できません。この端末の履歴を表示しています。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let loadError {
                Text(loadError).font(.caption)
            }
        }
        .listStyle(.plain)
        .task(id: scope + episodeID.rawValue.uuidString.lowercased()) {
            guard !Task.isCancelled else { return }
            isVisible = true
            cancelLoad()
            for await event in await application.stateChanges(for: workID) {
                guard !Task.isCancelled else { return }
                if event.concerns(workID) {
                    startLoad()
                }
            }
        }
        .onDisappear {
            isVisible = false
            cancelLoad()
        }
        .sheet(item: $preview) { version in
            NavigationStack {
                SnapshotEpisodePreview(application: application, workID: workID, snapshotID: version.body.snapshotID,
                                       episodeID: episodeID.rawValue.uuidString.lowercased(), heading: heading)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { preview = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 400)
            #endif
        }
        .confirmationDialog("この話を復元しますか？", isPresented: Binding(
            get: { request != nil }, set: {
                if !$0 {
                    request = nil
                }
            }
        ), presenting: request) { value in
            Button("この話を復元") {
                request = nil
                Task {
                    let capturedHost = host()
                    guard capturedHost.scope == scope else { return }
                    _ = await restore.restore(value, using: capturedHost,
                                              journal: EpisodeRestoreJournal(application: application, workID: workID))
                    startLoad()
                }
            }
            Button("キャンセル", role: .cancel) { request = nil }
        } message: { _ in Text(EpisodeRestoreSession.confirmation) }
        .disabled(restore.isRestoring)
    }

    private func row(_ version: EpisodeHistoryVersion, currentObjectID: ObjectID?, canRestore: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.extraSmall) {
            HStack(alignment: .firstTextBaseline) {
                Text(HistoryPresentation().time(version.item.createdAt)).monospacedDigit()
                EpisodeHistoryMetrics(application: application, workID: workID, episodeID: episodeID,
                                      reference: version.body, previous: version.previous, currentObjectID: currentObjectID)
            }
            if version.occurrences.count > 1, version.occurrences.allSatisfy(\.isAutosave) {
                Text(HistoryPresentation().autosaveLabel(.init(items: version.occurrences)) + " · " + deviceLabel(version.item))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(HistoryPresentation().subtitle(version.item) + " · " + deviceLabel(version.item))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("中身を見る") { preview = version }
                Button("この話を復元") { Task { await prepare(version) } }
                    .disabled(preparing || !canRestore)
            }
            .buttonStyle(.borderless)
        }
    }

    private func deviceLabel(_ item: SyncV2HistoryItem) -> String {
        item.displayDeviceLabel(currentLabel: DeviceLabel.current(deviceLabelOverride, defaultLabel: DeviceLabelSettings.defaultLabel))
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadRevision = UUID()
        loadingOlder = false
    }

    private func startLoad() {
        guard isVisible, host().scope == scope else { return }
        cancelLoad()
        let revision = loadRevision
        loadError = nil
        loadingOlder = true
        loadTask = Task { await load(revision: revision) }
    }

    private func load(revision: UUID) async {
        defer {
            if loadRevision == revision {
                loadingOlder = false
            }
        }
        do {
            var value = try await application.episodeHistory(workID: workID, episodeID: episodeID)
            while true {
                guard !Task.isCancelled, loadRevision == revision, host().scope == scope else { return }
                history = value
                loaded = true
                guard value.isLoadingOlder else { break }
                // Give SwiftUI the first page before continuing the owned task.
                await Task.yield()
                value = try await application.olderEpisodeHistory(value)
            }
        } catch {
            guard !Task.isCancelled, loadRevision == revision, host().scope == scope else { return }
            loaded = true
            loadError = "履歴を読み込めませんでした。"
        }
    }

    private func prepare(_ version: EpisodeHistoryVersion) async {
        let capturedHost = host()
        guard !preparing, capturedHost.scope == scope, capturedHost.validate(), let before = currentBody() else { return }
        preparing = true
        defer { preparing = false }
        do {
            let after = try await application.snapshotEpisodePreview(workID: workID, snapshotID: version.body.snapshotID,
                                                                     episodeID: episodeID.rawValue.uuidString.lowercased())
            guard !Task.isCancelled, capturedHost.validate(), currentBody()?.utf8.elementsEqual(before.utf8) == true else { return }
            request = EpisodeRestoreRequest(scope: scope, chapterID: chapterID, episodeID: episodeID, before: before, after: after)
        } catch {
            guard !Task.isCancelled, capturedHost.scope == host().scope else { return }
            restore.message = "本文を読み込めませんでした。復元していません。"
        }
    }
}

private struct EpisodeHistoryMetrics: View {
    let application: SyncV2Application
    let workID: WorkID
    let episodeID: EpisodeID
    let reference: EpisodeBodyReference
    let previous: EpisodeBodyReference?
    let currentObjectID: ObjectID?
    @State private var count: Int?
    @State private var previousCount: Int?
    @State private var failed = false

    private var current: Bool {
        currentObjectID == reference.entry.objectId
    }

    var body: some View {
        HStack(spacing: Spacing.extraSmall) {
            if let count {
                if let previousCount {
                    let delta = count - previousCount
                    Text("\(delta >= 0 ? "+" : "")\(delta.formatted())字（\(count.formatted())字）")
                        .foregroundStyle(previousCount > 0 && count <= previousCount / 2 ? FuminiwaColor.warning.color : .secondary)
                } else {
                    Text("\(count.formatted())字").foregroundStyle(.secondary)
                }
            } else {
                Text(failed ? "字数を確認できません" : "字数を確認中…").foregroundStyle(.secondary)
            }
            if current {
                Text("現在").font(.caption).foregroundStyle(FuminiwaColor.accent.color)
            }
        }
        .font(.subheadline).monospacedDigit()
        .task(id: [reference, previous]) {
            count = nil
            previousCount = nil
            failed = false
            do {
                let value = try await application.episodeHistoryCharacterCount(workID: workID, body: reference, episodeID: episodeID)
                let old: Int? = if let previous {
                    try await application.episodeHistoryCharacterCount(workID: workID, body: previous, episodeID: episodeID)
                } else {
                    nil
                }
                guard !Task.isCancelled else { return }
                count = value
                previousCount = old
            } catch {
                if !Task.isCancelled {
                    failed = true
                }
            }
        }
    }
}
