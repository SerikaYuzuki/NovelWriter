@testable import EditorKit
import Testing

/// `EditorView` はコンパイル時に import・構築できることをコンパイルレベルで確認する
/// だけのテスト(AppKit の実描画は自動テストしない。docs/DESIGN.md 4.3)。
///
/// `EditorView` の Public API に `NSTextView` / `UITextView` が出てこないこと
/// (docs/DESIGN.md 9.2)も、このテストがそのまま成立すること自体で担保される。
@MainActor
struct EditorViewConstructionTests {
    @Test("chapterKey / initialText / onTextChange だけで EditorView を構築できる")
    func canConstructEditorView() {
        var receivedText: String?
        let view = EditorView(
            chapterKey: "chapter-1",
            initialText: "本文",
            onTextChange: { text in receivedText = text }
        )

        // 構築できたこと自体がこのテストの目的。念のため型を確認しておく。
        #expect(type(of: view) == EditorView.self)
        // onTextChange をまだ誰も呼んでいないことの確認(未使用警告避けも兼ねる)。
        #expect(receivedText == nil)
    }
}
