import SwiftUI

/// The shelf owns its title/optional leading thumbnail; this is its single status slot.
public struct LibraryImportProgress: View {
    private let startedAt: Date
    private let longImportNotice: String

    public init(startedAt: Date, longImportNotice: String) {
        self.startedAt = startedAt
        self.longImportNotice = longImportNotice
    }

    public var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                HStack(spacing: Spacing.small) {
                    ProgressView().controlSize(.small)
                        .tint(FuminiwaColor.accent.color)
                        .accessibilityHidden(true)
                    Text("作品を取り込み中…")
                        .foregroundStyle(FuminiwaColor.accent.color)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("作品の取り込み")
                .accessibilityValue("取り込み中")
                if context.date.timeIntervalSince(startedAt) >= 15 {
                    Text(longImportNotice)
                        .foregroundStyle(FuminiwaColor.textSecondary.color)
                }
            }
            .font(FuminiwaType.rowSecondary)
        }
    }
}
