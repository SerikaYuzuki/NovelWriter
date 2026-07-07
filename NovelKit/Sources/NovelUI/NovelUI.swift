import NovelCore
import SwiftUI

/// NovelUI
///
/// 再利用可能な SwiftUI 部品を置くモジュール。`SidebarRow` などは Phase 1 以降で
/// 実装する(docs/DESIGN.md 4.6)。可能な限りプラットフォーム非依存にする。
///
/// 依存: NovelCore のみ(docs/DESIGN.md 9.1)。
public enum NovelUI {
    /// パッケージ雛形の版数。Phase 1 で実装導入後は用途を終える。
    public static let placeholderVersion = "0.0.0-scaffold"
}
