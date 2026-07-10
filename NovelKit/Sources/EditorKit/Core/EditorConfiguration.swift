import Foundation

/// エディタ表示設定。
///
/// AppKit/UIKit の型を公開APIに出さず、値型だけで本文エディタの見た目を指定する。
public struct EditorConfiguration: Hashable, Sendable {
    public static let defaultTextColorHex = "#E8E6DF"
    public static let defaultBackgroundColorHex = "#171719"

    /// フォント名。見つからない場合はプラットフォームのシステムフォントへフォールバックする。
    public var fontName: String
    /// フォントサイズ(pt)。
    public var fontSize: Double
    /// 行間倍率。
    public var lineHeightMultiple: Double
    /// 本文文字色。`#RRGGBB` 形式。プラットフォーム側で解釈できない場合は既定色へフォールバックする。
    public var textColorHex: String
    /// 本文背景色。`#RRGGBB` 形式。プラットフォーム側で解釈できない場合は既定色へフォールバックする。
    public var backgroundColorHex: String

    public init(
        fontName: String = "Hiragino Mincho ProN",
        fontSize: Double = 16,
        lineHeightMultiple: Double = 1.5,
        textColorHex: String = Self.defaultTextColorHex,
        backgroundColorHex: String = Self.defaultBackgroundColorHex
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineHeightMultiple = lineHeightMultiple
        self.textColorHex = textColorHex
        self.backgroundColorHex = backgroundColorHex
    }
}
