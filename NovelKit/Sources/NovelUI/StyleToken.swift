#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// docs/STYLE.md 2章で定義された、セマンティックカラー以外で使ってよい固定トークン。
///
/// `.orange` / `.green` のような場当たりの固定色の代わりに、これらのトークンを使う。
/// 新しいトークンを増やしたくなったら、まず STYLE.md を更新する PR を出すこと
/// (STYLE.md「変更の手続き」章)。
public enum StyleToken {
    /// 未回収の伏線・注意バッジ。
    public static var warning: Color {
        Color(light: "#B96A00", dark: "#E8A54A")
    }

    /// 回収済み・完了表示(控えめに使う)。
    public static var success: Color {
        Color(light: "#3D7A46", dark: "#7FBF8A")
    }
}

#if canImport(AppKit)
private typealias PlatformColor = NSColor
#elseif canImport(UIKit)
private typealias PlatformColor = UIColor
#endif

#if canImport(AppKit) || canImport(UIKit)
private func platformColor(hex: String) -> PlatformColor {
    guard let components = ColorHex.components(from: hex) else {
        #if canImport(AppKit)
        return PlatformColor.labelColor
        #else
        return PlatformColor.label
        #endif
    }
    return PlatformColor(
        red: CGFloat(components.red) / 255,
        green: CGFloat(components.green) / 255,
        blue: CGFloat(components.blue) / 255,
        alpha: 1
    )
}
#endif

extension Color {
    /// ライト/ダークで異なる hex を指定できる `Color` イニシャライザ。
    ///
    /// `NovelUI` はライブラリでアプリバンドルの Asset Catalog を持てないため、
    /// Assets の AccentColor のような2アピアランス管理をコードだけで行うための
    /// ユーティリティ。`NSColor(name:dynamicProvider:)` / `UIColor { traits in }` の
    /// 動的カラーを使い、外観の切り替えに自動追従する。
    init(light: String, dark: String) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return platformColor(hex: isDark ? dark : light)
        }))
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            platformColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self = Color(hex: light) ?? .primary
        #endif
    }
}
