#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

extension MacTextAdapterIntegrationTests {
    @Test("IME確定後のR5: 行頭の字下げを鉤括弧直後に削除し、Undoで戻せる")
    func imeCommitRemovesIndentAndUndoRestoresIt() {
        let harness = makeHarness(initialText: "　")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.setMarkedText(
            "「",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 1, length: 0)
        )
        #expect(textView.string == "　「")
        #expect(textView.hasMarkedText())

        textView.unmarkText()

        #expect(textView.string == "「")
        #expect(harness.changes.received == ["「"])
        #expect(harness.coordinator.undoManager.canUndo)

        harness.coordinator.undoManager.undo()

        // Undo一回でIME確定前の字下げ状態に戻る。
        #expect(textView.string == "　")
        #expect(harness.changes.received == ["「", "　"])

        #expect(harness.coordinator.undoManager.canRedo)
        harness.coordinator.undoManager.redo()

        #expect(textView.string == "「")
        #expect(harness.changes.received == ["「", "　", "「"])
    }

    @Test("IME確定後の括弧ペアでも字下げを削除し、Undoで戻せる")
    func imeCommitRemovesIndentBeforeBracketPairAndSupportsUndo() {
        let harness = makeHarness(initialText: "　")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.setMarkedText(
            "「」",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 1, length: 0)
        )
        #expect(textView.string == "　「」")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(textView.hasMarkedText())

        textView.unmarkText()

        #expect(textView.string == "「」")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        #expect(harness.changes.received == ["「」"])

        harness.coordinator.undoManager.undo()

        #expect(textView.string == "　")
        #expect(harness.changes.received == ["「」", "　"])

        harness.coordinator.undoManager.redo()

        #expect(textView.string == "「」")
        #expect(harness.changes.received == ["「」", "　", "「」"])
    }

    @Test("IME確定後は字下げなしの文中でもキャレットを括弧内へ移す")
    func imeCommitPlacesCaretInsideMidSentencePair() {
        let harness = makeHarness(initialText: "彼はと言った")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.setMarkedText(
            "『』",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 2, length: 0)
        )
        #expect(textView.string == "彼は『』と言った")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 0))

        textView.unmarkText()

        #expect(textView.string == "彼は『』と言った")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(harness.changes.received == ["彼は『』と言った"])
    }
}
#endif
