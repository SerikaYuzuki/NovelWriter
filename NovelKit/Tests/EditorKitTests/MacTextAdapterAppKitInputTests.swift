#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

extension MacTextAdapterIntegrationTests {
    @Test("AppKitの実入力経路でも字下げ直後の「で全角スペースが消える")
    func appKitInsertTextRemovesIndentBeforeOpeningBracket() {
        let harness = makeHarness(initialText: "\u{3000}")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.insertText(
            "「",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(textView.string == "「")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        #expect(harness.changes.received == ["「"])

        #expect(harness.coordinator.undoManager.canUndo)
        harness.coordinator.undoManager.undo()
        #expect(textView.string == "　")
    }

    @Test("IMEがinsertTextで「を確定しても段落字下げが消える")
    func imeInsertTextCommitRemovesIndentBeforeOpeningBracket() {
        let harness = makeHarness(initialText: "\u{3000}")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.setMarkedText(
            "「",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 1, length: 0)
        )
        let markedRange = textView.markedRange()
        #expect(markedRange == NSRange(location: 1, length: 1))

        textView.insertText("「", replacementRange: markedRange)

        #expect(textView.string == "「")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        #expect(harness.changes.received == ["「"])

        #expect(harness.coordinator.undoManager.canUndo)
        harness.coordinator.undoManager.undo()
        #expect(textView.string == "　")
    }

    @Test("AppKitから開閉括弧が別々に入力されても文中の空ペア内へキャレットを置く")
    func appKitSequentialBracketInputPlacesCaretInsideMidSentence() {
        let harness = makeHarness(initialText: "彼はと言った")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.insertText(
            "「",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.insertText(
            "」",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(textView.string == "彼は「」と言った")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))

        #expect(harness.coordinator.undoManager.canUndo)
        harness.coordinator.undoManager.undo()
        if textView.string != "彼はと言った", harness.coordinator.undoManager.canUndo {
            harness.coordinator.undoManager.undo()
        }
        #expect(textView.string == "彼はと言った")
    }

    @Test("IMEがinsertTextで括弧ペアを確定しても文中のペア内へキャレットを置く")
    func imeInsertTextCommitPlacesCaretInsideMidSentencePair() {
        let harness = makeHarness(initialText: "彼はと言った")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.setMarkedText(
            "「」",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 2, length: 0)
        )
        let markedRange = textView.markedRange()
        #expect(markedRange == NSRange(location: 2, length: 2))

        textView.insertText("「」", replacementRange: markedRange)

        #expect(textView.string == "彼は「」と言った")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(harness.changes.received == ["彼は「」と言った"])
    }
}
#endif
