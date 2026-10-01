import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum FuminiwaColor: String, CaseIterable, Sendable {
    case paper
    case surface
    case elevatedSurface
    case sunken
    case separator
    case textPrimary
    case textSecondary
    case textTertiary
    case accent
    case accentMuted
    case leaf
    case warning
    case danger

    public var rgb: (light: UInt32, dark: UInt32) {
        switch self {
        case .paper: (0xF8F5EF, 0x18181B)
        case .surface: (0xFFFDF9, 0x212126)
        case .elevatedSurface: (0xFFFFFF, 0x2A2A30)
        case .sunken: (0xF0ECE3, 0x131316)
        case .separator: (0xE3DDD1, 0x3A3B42)
        case .textPrimary: (0x23211D, 0xECE9E2)
        case .textSecondary: (0x6B655B, 0xA6A29A)
        case .textTertiary: (0x9A9488, 0x706C66)
        case .accent: (0x34558B, 0x8CA7DF)
        case .accentMuted: (0xE4E9F3, 0x263049)
        case .leaf: (0x50704A, 0x9DB58E)
        case .warning: (0x9A5A00, 0xE8A54A)
        case .danger: (0xB3413B, 0xE07A7A)
        }
    }

    public var color: Color {
        let pair = rgb
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.dark : pair.light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            return UIColor(red: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
        #endif
    }
}
