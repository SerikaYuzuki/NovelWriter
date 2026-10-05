import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import NovelWorkspace
import NovelWorkspaceUI
import SwiftUI

struct IOSLibraryImportRow: View {
    @Environment(WorkspaceModel.self) private var workspace
    let store: IOSDocumentStore
    let item: SyncV2LibraryItem
    let isRenaming: Bool
    let open: () -> Void
    let rename: () -> Void
    var isGrid = false
    var delete: () -> Void = {}

    @State private var cardWidth: CGFloat = 140
    @Environment(\.colorScheme) private var colorScheme

    private var isImporting: Bool {
        store.snapshotSyncV2RemoteOnlyOpeningWorkID == item.workID || store.libraryPrefetchWorkID == item.workID
    }

    private var phase: ImportPhase {
        workspace.libraryImportPhases[item.workID] ?? ImportPhase()
    }

    var body: some View {
        if isGrid {
            rowContent
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .contextMenu { menuItems } preview: {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        cover
                        titleAndStatus
                    }
                    .frame(width: cardWidth, alignment: .leading)
                    .background(FuminiwaColor.paper.color)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .environment(\.colorScheme, colorScheme)
                }
        } else {
            rowContent.contextMenu { menuItems }
        }
    }

    private var rowContent: some View {
        let layout = isGrid ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.small)) : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.small))
        return layout {
            Button(action: open) {
                cover
            }.buttonStyle(.plain).disabled(isRenaming || workspace.pendingDeletionWorkIDs.contains(item.workID))
                .accessibilityLabel("\(item.title)を開く")
            VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                Button(action: open) {
                    titleAndStatus
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRenaming || workspace.pendingDeletionWorkIDs.contains(item.workID))
                .accessibilityHint(isRenaming ? "作品名を変更中です" : isImporting ? LibraryImportProgress.hint(SyncV2LibraryPresentation.longImportNotice) :
                    item.availability == .remoteOnly ? SyncV2LibraryPresentation.remoteOnlyHint : "")
                if let note = item.historyBackfillNote, let application = store.snapshotSyncV2Application {
                    HistoryFetchControls(application: application, workID: item.workID, snapshotID: nil, progressNote: note, userDefaults: store.userDefaults)
                        .id(store.snapshotSyncV2AccountScope)
                }
                if isImporting {
                    Button(isGrid ? "中止" : "取り込みを中止") { Task { await store.cancelLibraryImport() } }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                } else if workspace.libraryImportFailures[item.workID] != nil {
                    Button("再試行") { store.takeOntoDevice(workID: item.workID, title: item.title) }
                        .tint(FuminiwaColor.accent.color)
                        .help(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil ? "ほかの作品を取り込み中です" : "この端末へ取り込み直します")
                        .accessibilityHint(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil ? "ほかの作品を取り込み中です" : "この端末へ取り込み直します")
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                        .disabled(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
                }
            }
        }
    }

    @ViewBuilder private var menuItems: some View {
        if item.availability == .remoteOnly {
            Button("この端末に取り込む", systemImage: "arrow.down.circle") {
                store.takeOntoDevice(workID: item.workID, title: item.title)
            }
            .disabled(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
            .accessibilityHint(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil
                ? SyncV2LibraryPresentation.importBusyReason : "開かずにこの端末へ保存します")
        }
        if isImporting {
            Text(LibraryImportProgress.hint(SyncV2LibraryPresentation.longImportNotice))
            Button("取り込みを中止") { Task { await store.cancelLibraryImport() } }
        }
        if workspace.libraryImportFailures[item.workID] != nil {
            Button("再試行") { store.takeOntoDevice(workID: item.workID, title: item.title) }
                .tint(FuminiwaColor.accent.color)
                .help(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil ? "ほかの作品を取り込み中です" : "この端末へ取り込み直します")
                .accessibilityHint(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil ? "ほかの作品を取り込み中です" : "この端末へ取り込み直します")
                .disabled(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
        }
        Button(LibraryText.rename, systemImage: "pencil", action: rename)
            .disabled(isRenaming || isImporting || workspace.pendingDeletionWorkIDs.contains(item.workID))
        deletionButton
        if let reason = store.libraryDeletionDisabledReason(for: item.workID) {
            Text(reason)
        }
    }

    private var cover: some View {
        LazyCoverThumbnail(title: item.title, identity: "\(item.workID)-\(store.snapshotSyncV2AccountScope)-\(item.localGeneration ?? 0)", size: isGrid ? 120 : 32) {
            guard item.availability != .remoteOnly else { return nil }
            let account = store.snapshotSyncV2AccountScope
            let bytes = try? await store.snapshotSyncV2Application?.localCoverThumbnail(workID: item.workID)
            guard account == store.snapshotSyncV2AccountScope else { return nil }
            return bytes
        }
    }

    private var titleAndStatus: some View {
        VStack(alignment: .leading, spacing: Spacing.extraSmall) {
            Text(item.title.isEmpty ? "名称未設定の作品" : item.title)
                .font(isGrid ? FuminiwaType.shelfTitle : .body)
                .truncationMode(.tail).lineLimit(isGrid ? 2 : nil)
                .foregroundStyle(FuminiwaColor.textPrimary.color)
            status
        }
    }

    private var deletionButton: some View {
        Button("作品を削除…", systemImage: "trash", role: .destructive, action: delete)
            .disabled(isRenaming || store.libraryDeletionDisabledReason(for: item.workID) != nil)
            .accessibilityLabel("「\(item.title)」を削除")
            .accessibilityHint(store.libraryDeletionDisabledReason(for: item.workID) ?? "確認画面を表示します")
    }

    @ViewBuilder private var status: some View {
        if workspace.pendingDeletionWorkIDs.contains(item.workID) {
            StatusLabel(LibraryText.pendingDeletion, systemImage: "clock", tone: .secondary)
                .font(FuminiwaType.rowSecondary)
        } else if isImporting, let startedAt = store.snapshotSyncV2RemoteOnlyOpenStartedAt {
            LibraryImportProgress(startedAt: startedAt, longImportNotice: SyncV2LibraryPresentation.longImportNotice,
                                  label: phase.japaneseLabel, fraction: phase.stage == .receiving ? phase.fraction : nil,
                                  accessibilityValue: phase.accessibilityValue, compact: isGrid)
        } else if let failure = workspace.libraryImportFailures[item.workID] {
            StatusLabel(SyncV2LibraryPresentation.importFailure(failure), systemImage: "exclamationmark.circle", tone: .danger)
                .font(FuminiwaType.rowSecondary)
        } else if isRenaming {
            ProgressView("作品名を変更中…")
        } else {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                StatusLabel(item.status.text, systemImage: item.status.symbol,
                            tone: StatusTone(rawValue: item.status.tone.rawValue) ?? .secondary)
                    .font(FuminiwaType.rowSecondary)
            }
        }
    }
}
