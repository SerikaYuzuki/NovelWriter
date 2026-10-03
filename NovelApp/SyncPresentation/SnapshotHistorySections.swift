import NovelSyncV2Application
import NovelUI
import SwiftUI

/// All history surfaces share ordering, grouping, accessible labels and row appearance.
struct SnapshotHistorySections<Row: View>: View {
    let items: [SyncV2HistoryItem]
    var presentation = HistoryPresentation()
    @ViewBuilder var row: (SyncV2HistoryItem) -> Row

    var body: some View {
        ForEach(presentation.days(items)) { day in
            Section {
                ForEach(day.runs) { run in
                    if run.isCollapsedAutosave {
                        DisclosureGroup {
                            ForEach(run.items, id: \.occurrenceID, content: row)
                        } label: {
                            Label(presentation.autosaveLabel(run), systemImage: "clock")
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
