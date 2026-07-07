import NovelCore

/// EditorKit
///
/// 本文エディタを提供するモジュール。macOS では `NSTextView`、iOS では将来
/// `UITextView` をアダプタ経由で利用する(docs/DESIGN.md 4.3)。
///
/// 依存: NovelCore のみ(docs/DESIGN.md 9.1)。
/// 実装ルール(docs/DESIGN.md 9.2): AppKit / UIKit は `Platform/` 配下に閉じ込め、
/// Public API に `NSTextView` / `UITextView` を出してはならない。
///
/// ディレクトリ構成(Phase 2 以降で中身を実装):
/// - `Core/`     EditorPlugin / EditorContext などのプロトコル
/// - `Rules/`    自動インデントなどの純粋な判定ロジック
/// - `Plugins/`  IndentPlugin / IMEGuardPlugin などの具象プラグイン
/// - `Platform/macOS/` AppKit 依存の実装(`#if canImport(AppKit)` で保護)
public enum EditorKit {
    /// パッケージ雛形の版数。Phase 2 で実装導入後は用途を終える。
    public static let placeholderVersion = "0.0.0-scaffold"
}
