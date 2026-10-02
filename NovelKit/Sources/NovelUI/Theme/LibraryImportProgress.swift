import SwiftUI

/// The shelf owns its title/optional leading thumbnail; this is its single status slot.
public struct LibraryImportProgress: View {
    private let startedAt: Date
    private let longImportNotice: String
    private let label: String
    private let fraction: Double?
    private let value: String
    private let compact: Bool

    public static func hint(_ notice: String) -> String {
        "アプリを閉じると中断します。" + notice
    }

    public init(startedAt: Date, longImportNotice: String, label: String = "サーバーから受信中 0.0 MB",
                fraction: Double? = nil, accessibilityValue: String = "取り込み中", compact: Bool = false) {
        self.compact = compact
        self.label = label
        self.fraction = fraction
        value = accessibilityValue
        self.startedAt = startedAt
        self.longImportNotice = longImportNotice
    }

    public var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                HStack(spacing: Spacing.small) {
                    if !compact, fraction == nil {
                        ProgressView().controlSize(.small)
                            .tint(FuminiwaColor.accent.color)
                            .accessibilityHidden(true)
                    } else if !compact {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(FuminiwaColor.accent.color)
                            .accessibilityHidden(true)
                    }
                    Text(compact ? label.replacingOccurrences(of: "サーバーから", with: "") : label).monospacedDigit()
                        .foregroundStyle(FuminiwaColor.accent.color)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("作品の取り込み")
                .accessibilityValue(value)
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(FuminiwaColor.leaf.color)
                        .accessibilityHidden(true)
                }
                if !compact {
                    #if os(iOS)
                    Text("アプリを閉じると中断します")
                        .foregroundStyle(FuminiwaColor.textSecondary.color)
                    #endif
                    if context.date.timeIntervalSince(startedAt) >= 15 {
                        Text(longImportNotice)
                            .foregroundStyle(FuminiwaColor.textSecondary.color)
                    }
                }
            }
            .accessibilityHint(Self.hint(longImportNotice))
            .help(Self.hint(longImportNotice))
            .font(compact ? .caption : FuminiwaType.rowSecondary)
        }
    }
}
