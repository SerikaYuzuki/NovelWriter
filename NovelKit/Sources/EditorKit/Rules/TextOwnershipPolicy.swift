/// テキスト所有権ルール(docs/DESIGN.md 4.3, docs/DECISIONS.md D-005)のうち、
/// プラットフォーム非依存に切り出せる判定ロジックを置く。
///
/// docs/DESIGN.md 9.4 の方針どおり、AppKit / UIKit には一切依存しない純粋な判定
/// ロジックとしてここに切り出し、`MacTextAdapter`(将来的には iOS アダプタも)から
/// 共通で使う。
enum TextOwnershipPolicy {
    /// 本文をテキストビューへ流し込み直すべきかどうかを判定する。
    ///
    /// テキスト所有権ルールの核心: モデル → View への反映は章切り替え時のみ行い、
    /// 同じ章のまま SwiftUI の再描画が走っても、編集中の内容を外部から
    /// 上書きしてはならない(docs/DESIGN.md 4.3, D-005)。
    ///
    /// - Parameters:
    ///   - previousChapterKey: 直前に表示していた章のキー。まだ何も表示していない
    ///     場合は `nil`。
    ///   - newChapterKey: これから表示しようとしている章のキー。
    /// - Returns: 章が変わっていて本文を流し込み直すべきなら `true`。
    static func shouldLoadText(previousChapterKey: AnyHashable?, newChapterKey: AnyHashable) -> Bool {
        previousChapterKey != newChapterKey
    }

    /// 本文変更をモデルへ通知してよいかどうかを判定する。
    ///
    /// IME 変換中(`hasMarkedText`)は、プラグイン処理・モデル反映ともに行わない
    /// (docs/DESIGN.md 4.3)。変換確定後の `textDidChange` で最新の全文が届くため、
    /// 変換中の中間状態を逃してもデータは失われない。
    ///
    /// - Parameter hasMarkedText: テキストビューが変換中の未確定文字列
    ///   (マークされたテキスト)を持っているかどうか。
    /// - Returns: モデルへ通知してよいなら `true`。
    static func shouldNotifyTextChange(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }
}
