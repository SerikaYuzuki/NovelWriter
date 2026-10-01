import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

struct IOSLibraryImportRow: View {
    let store: IOSDocumentStore
    let item: SyncV2LibraryItem
    let isRenaming: Bool
    let open: () -> Void
    let rename: () -> Void

    private var isImporting: Bool {
        store.snapshotSyncV2RemoteOnlyOpeningWorkID == item.workID || store.libraryPrefetchWorkID == item.workID
    }

    private var phase: ImportPhase {
        store.libraryImportPhases[item.workID] ?? ImportPhase()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            LazyCoverThumbnail(title: item.title, identity: "\(item.workID)-\(store.snapshotSyncV2AccountScope)-\(item.localGeneration ?? 0)") {
                guard item.availability != .remoteOnly else { return nil }
                let account = store.snapshotSyncV2AccountScope
                let bytes = try? await store.snapshotSyncV2Application?.localCoverThumbnail(workID: item.workID)
                guard account == store.snapshotSyncV2AccountScope else { return nil }
                return bytes
            }
            VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                        Text(item.title.isEmpty ? "名称未設定の作品" : item.title)
                            .foregroundStyle(FuminiwaColor.textPrimary.color)
                        status
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRenaming)
                .accessibilityHint(isRenaming ? "作品名を変更中です" : isImporting ? "この作品を取り込み中です" :
                    item.availability == .remoteOnly ? SyncV2LibraryPresentation.remoteOnlyHint : "")
                if isImporting {
                    Button("取り込みを中止") { Task { await store.cancelLibraryImport() } }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                } else if store.libraryImportFailures[item.workID] != nil {
                    Button("再試行") { store.takeOntoDevice(workID: item.workID, title: item.title) }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                        .disabled(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
                        .accessibilityHint(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil
                            ? SyncV2LibraryPresentation.importBusyReason : "開かずにこの端末へ保存します")
                }
            }
        }
        .contextMenu {
            if item.availability == .remoteOnly {
                Button("この端末に取り込む", systemImage: "arrow.down.circle") {
                    store.takeOntoDevice(workID: item.workID, title: item.title)
                }
                .disabled(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil)
                .accessibilityHint(store.libraryPrefetchWorkID != nil || store.snapshotSyncV2RemoteOnlyOpeningWorkID != nil
                    ? SyncV2LibraryPresentation.importBusyReason : "開かずにこの端末へ保存します")
            }
            if isImporting {
                Button("取り込みを中止") { Task { await store.cancelLibraryImport() } }
            }
            Button("作品名を変更", systemImage: "pencil", action: rename)
                .disabled(isRenaming || isImporting)
        }
    }

    @ViewBuilder private var status: some View {
        if isImporting, let startedAt = store.snapshotSyncV2RemoteOnlyOpenStartedAt {
            LibraryImportProgress(startedAt: startedAt, longImportNotice: SyncV2LibraryPresentation.longImportNotice,
                                  label: phase.japaneseLabel, fraction: phase.stage == .receiving ? phase.fraction : nil,
                                  accessibilityValue: phase.accessibilityValue)
        } else if let failure = store.libraryImportFailures[item.workID] {
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
