import Foundation

/// ``EditorPlugin/shouldChange(context:range:replacement:)`` が返す判定結果(docs/DESIGN.md 4.4)。
///
/// docs/DESIGN.md の想定プロトコルからの拡張(Phase 2 実装にあたり指揮者承認済み。
/// 差分は最終レポートにも明記する):
///
/// - `replace` に `range` を追加した。DESIGN.md の草案は `shouldChange` に渡された
///   `range` をそのまま置換対象とする前提だったが、``IndentRules`` の R2/R3 は
///   「行頭の空白全体」や「字下げ済みの全角スペース1文字」など、提案された範囲より
///   広い/別の範囲を置き換える必要がある。そのため置換対象の範囲をプラグイン側から
///   明示できるようにした。
/// - `allowSkippingRemaining` を追加した。``IMEGuardPlugin`` が「この入力には介入
///   しないが、以降のプラグイン(``IndentPlugin`` など)も一切実行させたくない」ことを
///   表明するための専用ケース。素の `allow` は「このプラグインは何もしないので次の
///   プラグインに委ねる」という意味であり、両者は区別する必要がある
///   (IME変換中に後続プラグインが介入するとテキスト所有権ルールに違反するため)。
public enum EditorAction: Equatable {
    /// このプラグインは介入しない。パイプラインは次のプラグインを試す。
    case allow

    /// このプラグインは介入しないが、以降のプラグインの実行もスキップして
    /// 入力をそのまま許可する(IME変換中など)。
    case allowSkippingRemaining

    /// `range` を `text` に置き換える。
    ///
    /// - `range`: 置換対象の範囲(UTF-16 の `NSRange`)。`shouldChange` に渡された
    ///   `range` と同じとは限らない。
    /// - `text`: 置換後のテキスト。
    /// - `caretOffset`: 置換後、`range.location` を起点として数えたキャレット位置
    ///   (UTF-16 オフセット)。
    case replace(range: NSRange, text: String, caretOffset: Int)
}

/// 入力前・入力後の処理を分離するためのプラグインプロトコル(docs/DESIGN.md 4.4)。
///
/// `EditorView` / `MacTextAdapter` を肥大化させないための拡張点。プラグインは単体で
/// テストできるよう、AppKit / UIKit に一切依存してはならない(``EditorContext`` を
/// 通じてのみ本文・IME状態にアクセスする。docs/DESIGN.md 9.4)。
public protocol EditorPlugin: AnyObject {
    /// 本文が変更される直前に呼ばれる。
    ///
    /// - Returns: この変更に対する判定。`.allow` を返すと次のプラグインが試される。
    func shouldChange(context: EditorContext, range: NSRange, replacement: String) -> EditorAction

    /// 本文が変更された直後(IME変換中を除く)に呼ばれる。
    func didChange(context: EditorContext)
}

/// 登録済みの ``EditorPlugin`` を順番に実行するパイプライン(docs/DESIGN.md 4.4)。
///
/// プラグインは登録順に実行され、最初に `.allow` 以外を返したプラグインで処理が
/// 確定する(順序に意味がある)。EditorKit の既定パイプラインは
/// `[IMEGuardPlugin(), IndentPlugin()]`(docs/DESIGN.md 4.3)。
public final class EditorPluginPipeline {
    private let plugins: [EditorPlugin]

    /// - Parameter plugins: 登録順に実行するプラグイン。
    public init(plugins: [EditorPlugin]) {
        self.plugins = plugins
    }

    /// 登録順にプラグインを試し、最初に `.allow` 以外を返したプラグインの結果で確定する。
    /// すべて `.allow` を返した場合は `.allow` を返す。
    public func shouldChange(context: EditorContext, range: NSRange, replacement: String) -> EditorAction {
        for plugin in plugins {
            let action = plugin.shouldChange(context: context, range: range, replacement: replacement)
            if case .allow = action {
                continue
            }
            return action
        }
        return .allow
    }

    /// 登録されているすべてのプラグインへ、登録順に変更後通知を届ける。
    public func didChange(context: EditorContext) {
        for plugin in plugins {
            plugin.didChange(context: context)
        }
    }
}
