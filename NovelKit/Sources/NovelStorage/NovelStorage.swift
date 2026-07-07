import NovelCore

/// NovelStorage
///
/// `.novelpkg` パッケージ(manifest.json + chapters/*.md + attachments/)の
/// 読み書きを担当するモジュール。`DocumentRepository` の実装は Phase 1 で行う
/// (docs/DESIGN.md 4.2)。
///
/// 依存: NovelCore のみ(docs/DESIGN.md 9.1)。
public enum NovelStorage {
    /// パッケージ雛形の版数。Phase 1 で実装導入後は用途を終える。
    public static let placeholderVersion = "0.0.0-scaffold"
}
