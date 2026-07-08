import Foundation

/// パイプライン先頭に置く、IME変換中の入力に他のプラグインを介入させないための
/// プラグイン(docs/DESIGN.md 4.3 テキスト所有権ルール, docs/DECISIONS.md D-005)。
///
/// 日本語IMEの変換中(``EditorContext/isIMEComposing``)は、``IndentPlugin`` などの
/// 後続プラグインが本文やキャレットに介入すると、変換中の未確定文字列が壊れ
/// 「不自然な巻き戻り」を引き起こす。``IMEGuardPlugin`` をパイプラインの先頭に
/// 登録することで、変換中は後続プラグインを一切実行させずに入力をそのまま許可する。
public final class IMEGuardPlugin: EditorPlugin {
    public init() {}

    public func shouldChange(context: EditorContext, range _: NSRange, replacement _: String) -> EditorAction {
        context.isIMEComposing ? .allowSkippingRemaining : .allow
    }

    public func didChange(context _: EditorContext) {
        // IME変換中かどうかに関わらず、このプラグイン自身は変更後に行うことがない。
    }
}
