import NovelCore

/// PreviewSupport
///
/// SwiftUI Preview 用の固定データを置くモジュール(docs/DESIGN.md 4.7)。
/// 各 Preview でダミーデータがバラつくのを防ぐ。Phase 1 以降で実装する。
///
/// 依存: NovelCore のみ(docs/DESIGN.md 9.1)。
public enum PreviewSupport {
    /// パッケージ雛形の版数。Phase 1 で実装導入後は用途を終える。
    public static let placeholderVersion = "0.0.0-scaffold"
}
