import Foundation

/// ``IndentRules`` の判定を ``EditorAction`` に変換するだけの薄いプラグイン
/// (docs/DESIGN.md 4.5)。
///
/// 判定ロジック自体は一切持たず、``IndentRules/action(for:in:range:)`` の結果を
/// そのまま ``EditorAction`` へ写像する。単体テストは ``IndentRules`` 側(純ロジック)
/// で行うため、このプラグイン自体のテストは薄くてよい。
public final class IndentPlugin: EditorPlugin {
    public init() {}

    public func shouldChange(context: EditorContext, range: NSRange, replacement: String) -> EditorAction {
        switch IndentRules.action(for: replacement, in: context.string, range: range) {
        case .allow:
            .allow
        case let .replace(range, text, caretOffset):
            .replace(range: range, text: text, caretOffset: caretOffset)
        }
    }

    public func didChange(context _: EditorContext) {
        // 改行・鉤括弧の自動整形は shouldChange 側で完結しており、変更後に
        // 行うことはない。
    }
}
