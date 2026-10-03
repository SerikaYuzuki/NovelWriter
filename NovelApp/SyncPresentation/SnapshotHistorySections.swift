import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

/// All history surfaces share ordering, grouping, accessible labels and row appearance.
struct SnapshotHistorySections<Row: View>: View {
    let items: [SyncV2HistoryItem]
    var application: SyncV2Application?
    var workID: WorkID?
    var presentation = HistoryPresentation()
    @State private var currentSnapshotID: SnapshotID?
    @ViewBuilder var row: (SyncV2HistoryItem) -> Row

    var body: some View {
        let context = SnapshotHistoryContext(items: items, presentation: presentation, currentSnapshotID: currentSnapshotID)
        ForEach(presentation.days(items)) { day in
            Section {
                ForEach(day.runs) { run in
                    if run.isCollapsedAutosave {
                        DisclosureGroup {
                            ForEach(run.items, id: \.occurrenceID, content: row)
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                                Label(presentation.autosaveLabel(run), systemImage: "clock")
                                if let currentSnapshotID, run.items.contains(where: { $0.snapshotID == currentSnapshotID }) {
                                    Text("現在").font(.caption).foregroundStyle(FuminiwaColor.accent.color)
                                }
                                if let application, let workID, let newest = run.items.first, let oldest = run.items.last {
                                    SnapshotDifferenceLine(application: application, workID: workID,
                                                           before: context.previous[oldest.occurrenceID], after: newest.snapshotID)
                                }
                            }
                            .font(FuminiwaType.rowSecondary)
                            .foregroundStyle(FuminiwaColor.textSecondary.color)
                            .accessibilityLabel(presentation.autosaveLabel(run))
                        }
                    } else {
                        row(run.items[0])
                    }
                }
            } header: {
                Text(day.title).font(.headline).accessibilityAddTraits(.isHeader)
            }
        }
        .environment(\.snapshotHistoryContext, context)
        .task(id: workID) {
            guard let application, let workID else { return }
            for await _ in await application.stateChanges(for: workID) {
                guard !Task.isCancelled else { return }
                let current = try? await application.currentSnapshotID(workID: workID)
                guard !Task.isCancelled else { return }
                currentSnapshotID = current
            }
        }
    }
}

struct SnapshotHistoryLabel: View {
    @AppStorage private var deviceLabelOverride: String

    init(item: SyncV2HistoryItem, presentation: HistoryPresentation = .init(), userDefaults: UserDefaults = .standard) {
        self.item = item
        self.presentation = presentation
        _deviceLabelOverride = AppStorage(wrappedValue: "", DeviceLabel.defaultsKey, store: userDefaults)
    }

    private var deviceLabel: String {
        item.displayDeviceLabel(currentLabel: DeviceLabel.current(deviceLabelOverride, defaultLabel: DeviceLabelSettings.defaultLabel))
    }

    let item: SyncV2HistoryItem
    var presentation = HistoryPresentation()

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                Text(presentation.time(item.createdAt))
                    .font(.body).monospacedDigit()
                    .foregroundStyle(item.isAutosave ? FuminiwaColor.textSecondary.color : FuminiwaColor.textPrimary
                        .color)
                Text(presentation.subtitle(item) + "・" + deviceLabel)
                    .font(FuminiwaType.rowSecondary)
                    .foregroundStyle(FuminiwaColor.textSecondary.color)
            }
        } icon: {
            Image(systemName: item.historySymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.isAutosave ? FuminiwaColor.textSecondary.color : FuminiwaColor.accent.color)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.label(item) + "・" + deviceLabel)
    }
}

/// Built once per history render, never once per row. Immutable metadata only.
struct SnapshotHistoryContext: Sendable {
    var currentSnapshotID: SnapshotID?
    var previous: [UUID: SnapshotID] = [:]
    var rejected: Set<UUID> = []

    init(items: [SyncV2HistoryItem] = [], presentation: HistoryPresentation = HistoryPresentation(),
         currentSnapshotID: SnapshotID? = nil) {
        self.currentSnapshotID = currentSnapshotID
        let ordered = presentation.days(items).flatMap(\.runs).flatMap(\.items)
        for (index, item) in ordered.enumerated() {
            if index + 1 < ordered.count {
                previous[item.occurrenceID] = ordered[index + 1].snapshotID
            }
            if presentation.isUnselectedConflictVersion(item, in: items) {
                rejected.insert(item.occurrenceID)
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var snapshotHistoryContext: SnapshotHistoryContext = .init()
}
