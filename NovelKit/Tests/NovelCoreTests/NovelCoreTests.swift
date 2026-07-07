import Testing
@testable import NovelCore

/// Phase 0 時点のプレースホルダテスト。
/// 実モデル(Chapter / NovelDocument 等)導入後にテストを差し替える(Phase 1)。
@Test func placeholderVersionIsNotEmpty() {
    #expect(!NovelCore.placeholderVersion.isEmpty)
}
