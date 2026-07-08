import Foundation

/// プラグインが本文やIME状態にアクセスするための抽象インターフェース(docs/DESIGN.md 4.4)。
///
/// `NSTextView` / `UITextView` を直接公開しないための境界であり(docs/DESIGN.md 9.2)、
/// `MacTextAdapter`(将来的には iOS アダプタも)が実際のテキストビューをラップして
/// このプロトコルに適合させる。プラグインは `EditorContext` を通じてのみ本文・IME状態に
/// アクセスできる。
public protocol EditorContext {
    /// 編集中の本文全体。
    var string: String { get }

    /// 日本語IMEなどが変換中(未確定文字列を保持している状態)かどうか。
    ///
    /// `true` の間は、プラグインは一切介入すべきではない
    /// (docs/DESIGN.md 4.3 テキスト所有権ルール, docs/DECISIONS.md D-005)。
    var isIMEComposing: Bool { get }

    /// `location`(UTF-16 オフセット)を含む行の範囲を返す。
    ///
    /// `NSString.lineRange(for:)` 相当で、行終端記号(`\n` など)を含む範囲を返す。
    func lineRange(at location: Int) -> NSRange
}
