@testable import EditorKit
import Testing

/// `TextOwnershipPolicy`(docs/DESIGN.md 4.3, docs/DECISIONS.md D-005)の
/// 純ロジック部分に対するテスト。AppKit / UIKit を必要としないため、
/// macOS / iOS どちらの `swift test` 環境でも実行できる。
struct TextOwnershipPolicyTests {
    @Test("初回表示(previous が nil)では必ず本文を流し込む")
    func shouldLoadTextWhenNoPreviousChapter() {
        #expect(TextOwnershipPolicy.shouldLoadText(previousChapterKey: nil, newChapterKey: "chapter-1"))
    }

    @Test("同じ章のままなら本文を流し込み直さない(編集中の内容を保持する)")
    func shouldNotReloadTextForSameChapter() {
        let key: AnyHashable = "chapter-1"
        #expect(!TextOwnershipPolicy.shouldLoadText(previousChapterKey: key, newChapterKey: key))
    }

    @Test("異なる章に切り替わったら本文を流し込み直す")
    func shouldReloadTextForDifferentChapter() {
        #expect(
            TextOwnershipPolicy.shouldLoadText(
                previousChapterKey: "chapter-1",
                newChapterKey: "chapter-2"
            )
        )
    }

    @Test("キーの型が異なれば別の章として扱う")
    func shouldReloadTextForDifferentUnderlyingType() {
        // AnyHashable は基になる型も含めて比較されるため、"1" と 1 は別のキー。
        #expect(
            TextOwnershipPolicy.shouldLoadText(
                previousChapterKey: AnyHashable("1"),
                newChapterKey: AnyHashable(1)
            )
        )
    }

    @Test("IME変換中(hasMarkedText)は本文変更を通知しない")
    func shouldNotNotifyWhileComposing() {
        #expect(!TextOwnershipPolicy.shouldNotifyTextChange(hasMarkedText: true))
    }

    @Test("変換確定後(hasMarkedTextがfalse)は本文変更を通知する")
    func shouldNotifyAfterComposingEnds() {
        #expect(TextOwnershipPolicy.shouldNotifyTextChange(hasMarkedText: false))
    }
}
