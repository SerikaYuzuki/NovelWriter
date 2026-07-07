/// NovelCore
///
/// アプリの中核となるデータ構造とプロトコルを置くモジュール。
/// 作品モデル・章モデル・ID型・保存層の抽象プロトコルは Phase 1 で実装する
/// (docs/DESIGN.md 4.1)。
///
/// 依存方向ルール(docs/DESIGN.md 9.1): NovelCore は他のどのモジュールにも、
/// UIフレームワークにも依存してはならない。Foundation 以外のフレームワークを
/// import してはならない。
public enum NovelCore {
    /// パッケージ雛形の版数。Phase 1 で実モデル導入後は用途を終える。
    public static let placeholderVersion = "0.0.0-scaffold"
}
