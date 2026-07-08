import Foundation

/// エディタ表示設定。
///
/// AppKit/UIKit の型を公開APIに出さず、値型だけで本文エディタの見た目を指定する。
public struct EditorConfiguration: Hashable, Sendable {
    /// フォント名。見つからない場合はプラットフォームのシステムフォントへフォールバックする。
    public var fontName: String
    /// フォントサイズ(pt)。
    public var fontSize: Double
    /// 行間倍率。
    public var lineHeightMultiple: Double

    public init(fontName: String = "Hiragino Mincho ProN", fontSize: Double = 16, lineHeightMultiple: Double = 1.5) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineHeightMultiple = lineHeightMultiple
    }
}
