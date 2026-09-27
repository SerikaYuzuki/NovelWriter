#if canImport(UIKit) && !canImport(AppKit)
@testable import EditorKit
import Testing
import UIKit

extension IOSTextAdapterIntegrationTests {
    @Test("iOS校正は離れた修正だけを色付けし、native UndoとRedoで一括して戻せる")
    func proofreadingHighlightsOnlyChangesAndUsesNativeUndo() async {
        let unchanged = String(repeating: "変えない文章。", count: 300)
        let original = "空は赤い。\n\(unchanged)\n猫は眠る。"
        let revised = "空は青い。\n\(unchanged)\n猫は走る。👩‍👩‍👧‍👦"
        let harness = makeHarness(initialText: original)
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        #expect(session.applyProofreading(expectedText: original, replacement: revised))
        #expect(harness.textView.textLayoutManager != nil)
        #expect(harness.changes.received == [revised])
        #expect(highlightedText(harness.textView) == ["青", "走", "👩‍👩‍👧‍👦"])
        for _ in 0 ..< 3 {
            await advanceMainRunLoop()
        }
        #expect(harness.undoManager.canUndo)
        harness.undoManager.undo()
        #expect(harness.textView.text == original)
        #expect(highlightedText(harness.textView).isEmpty)
        #expect(harness.changes.received.last == original)
        harness.undoManager.redo()
        #expect(harness.textView.text == revised)
        #expect(highlightedText(harness.textView) == ["青", "走", "👩‍👩‍👧‍👦"])
    }

    @Test("iOS校正は変換中・変更済み本文・読み取り専用への反映を拒否する")
    func proofreadingRejectsChangedOrComposingText() throws {
        let harness = makeHarness(initialText: "本文")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        #expect(!session.applyProofreading(expectedText: "古い本文", replacement: "変更"))
        harness.textView.isEditable = false
        #expect(!session.applyProofreading(expectedText: "本文", replacement: "変更"))
        harness.textView.isEditable = true
        harness.textView.selectedRange = NSRange(location: 2, length: 0)
        harness.textView.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0))
        try #require(harness.textView.markedTextRange != nil)
        let composing = harness.textView.text ?? ""
        #expect(!session.applyProofreading(expectedText: composing, replacement: "変更"))
        #expect(harness.textView.text == composing)
        #expect(harness.textView.markedTextRange != nil)
        #expect(harness.coordinator.proofreadingOriginal == nil)
    }

    @Test("iOS校正の色消去は本文・選択・表示位置・Undoを変更しない")
    func clearingProofreadingPreservesNativeEditorState() async {
        let original = String(repeating: "本文を変えない。\n", count: 200)
        let revised = "追加\n" + original
        let harness = makeHarness(initialText: original)
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        #expect(session.applyProofreading(expectedText: original, replacement: revised))
        for _ in 0 ..< 3 {
            await advanceMainRunLoop()
        }
        harness.textView.selectedRange = NSRange(location: 4, length: 2)
        harness.textView.layoutIfNeeded()
        harness.textView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        let offset = harness.textView.contentOffset
        let notifications = harness.changes.received
        session.clearProofreadingHighlights()
        session.clearProofreadingHighlights()
        #expect(harness.textView.text == revised)
        #expect(harness.textView.selectedRange == NSRange(location: 4, length: 2))
        #expect(harness.textView.contentOffset == offset)
        #expect(harness.changes.received == notifications)
        #expect(highlightedText(harness.textView).isEmpty)
        #expect(harness.textView.typingAttributes[.backgroundColor] == nil)
        harness.undoManager.undo()
        #expect(harness.textView.text == original)
        #expect(highlightedText(harness.textView).isEmpty)
        harness.undoManager.redo()
        #expect(harness.textView.text == revised)
        #expect(highlightedText(harness.textView).isEmpty)
    }

    @Test("iOS校正の後もIME確定が通知され、変換中に色を再計算しない")
    func proofreadingTracksCommittedIMEOnly() async throws {
        let harness = makeHarness(initialText: "本文")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        #expect(session.applyProofreading(expectedText: "本文", replacement: "校正本文"))
        harness.textView.selectedRange = NSRange(location: 4, length: 0)
        harness.textView.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0))
        try #require(harness.textView.markedTextRange != nil)
        harness.coordinator.textViewDidChange(harness.textView)
        #expect(harness.changes.received.last == "校正本文")
        session.clearProofreadingHighlights()
        #expect(harness.coordinator.proofreadingOriginal == "本文")
        harness.textView.unmarkText()
        for _ in 0 ..< 3 {
            await advanceMainRunLoop()
        }
        #expect(harness.changes.received.last == "校正本文へんかん")
        #expect(highlightedText(harness.textView) == ["校正", "へんかん"])
    }

    @Test("古いiOS editorの再登録では新しい本文への校正権限を奪わない")
    func proofreadingUsesActiveSurfaceOnly() {
        let old = makeHarness(initialText: "旧本文"), current = makeHarness(initialText: "新本文")
        let session = EditorCommandSession()
        old.coordinator.registerCommandSurface(with: session)
        current.coordinator.registerCommandSurface(with: session)
        old.coordinator.registerCommandSurface(with: session)
        #expect(!session.applyProofreading(expectedText: "旧本文", replacement: "変更"))
        #expect(session.applyProofreading(expectedText: "新本文", replacement: "校正本文"))
        #expect(old.textView.text == "旧本文")
        #expect(current.textView.text == "校正本文")
        current.coordinator.unregisterCommandSurface()
        #expect(!session.applyProofreading(expectedText: "校正本文", replacement: "変更"))
    }

    private func highlightedText(_ textView: UITextView) -> [String] {
        var result: [String] = []
        let storage = textView.textStorage
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { color, range, _ in
            if color != nil {
                result.append((storage.string as NSString).substring(with: range))
            }
        }
        return result
    }
}
#endif
