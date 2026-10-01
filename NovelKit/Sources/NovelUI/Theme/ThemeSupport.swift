import SwiftUI

public enum FuminiwaType {
    public static let workTitle = Font.custom("HiraMinProN-W6", size: 22, relativeTo: .title2)
    public static let coverInitial = Font.custom("HiraMinProN-W6", size: 34, relativeTo: .largeTitle)
    public static let groupTitle = Font.headline
    #if os(iOS)
    public static let rowSecondary = Font.subheadline
    #else
    public static let rowSecondary = Font.caption
    #endif
    public static let metadata = Font.caption2
}

public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let extraSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let group: CGFloat = 16
    public static let outer: CGFloat = 20
    public static let large: CGFloat = 24
    public static let extraLarge: CGFloat = 32
    public static let xxl: CGFloat = 48
}

public enum Radius {
    public static let chip: CGFloat = 4
    public static let thumbnail: CGFloat = 6
    public static let card: CGFloat = 10
    public static let hero: CGFloat = 14
    public static let cover: CGFloat = 4
}

public enum Motion {
    public static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }
}

private struct CoverShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 3, y: 1)
    }
}

public extension View {
    func coverShadow() -> some View {
        modifier(CoverShadow())
    }
}

public enum StatusTone: Sendable {
    case success, active, secondary, offline, warning, danger
    public var token: FuminiwaColor {
        switch self {
        case .success: .leaf
        case .active: .accent
        case .secondary: .textSecondary
        case .offline: .textTertiary
        case .warning: .warning
        case .danger: .danger
        }
    }

    public var textToken: FuminiwaColor {
        self == .offline ? .textSecondary : token
    }
}

public struct StatusLabel: View {
    private let title: String
    private let symbol: String
    private let tone: StatusTone
    public init(_ title: String, systemImage: String, tone: StatusTone) {
        self.title = title
        symbol = systemImage
        self.tone = tone
    }

    public var body: some View {
        Label {
            Text(title).foregroundStyle(tone.textToken.color)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tone.token.color).symbolRenderingMode(.hierarchical)
        }
        .labelStyle(.titleAndIcon)
    }
}
