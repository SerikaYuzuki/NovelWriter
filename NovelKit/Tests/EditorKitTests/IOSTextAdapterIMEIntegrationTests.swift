#if canImport(UIKit) && !canImport(AppKit)
@testable import EditorKit
import Testing
import UIKit

extension IOSTextAdapterIntegrationTests {
    @Test("IME確定の本文通知がcaret通知より先でもpendingを保持する")
    func imeCommitWaitsForFinalSelection() async {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        textView.text = "本文\n"
        textView.selectedRange = NSRange(location: 2, length: 0)
        harness.coordinator.hasPendingIMECommit = true
        harness.coordinator.pendingIMENewline = IOSPendingIMENewline(
            sourceText: "本文仮",
            replacementRange: NSRange(location: 2, length: 1),
            surfaceToken: harness.coordinator.commandSurfaceToken
        )

        harness.coordinator.textViewDidChange(textView)
        #expect(harness.coordinator.hasPendingIMECommit)
        #expect(textView.text == "本文\n")

        textView.selectedRange = NSRange(location: 3, length: 0)
        harness.coordinator.textViewDidChangeSelection(textView)
        await advanceMainRunLoop()

        #expect(!harness.coordinator.hasPendingIMECommit)
        #expect(textView.text == "本文\n　")
        #expect(textView.selectedRange == NSRange(location: 4, length: 0))
        #expect(harness.changes.received.last == "本文\n　")
    }

    @Test("UIKitのUndo groupが3 turnを超えてもPlugin操作のUndoを失わない")
    func pendingPluginUndoWaitsForUIKitGroupClosure() async {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: 2, length: 0)
        let groupsByEvent = harness.undoManager.groupsByEvent
        harness.undoManager.groupsByEvent = false
        harness.undoManager.beginUndoGrouping()

        harness.coordinator.applyPluginReplacement(
            range: textView.selectedRange,
            text: "\n　",
            caretOffset: 2,
            textView: textView
        )
        #expect(textView.text == "本文\n　")

        for _ in 0 ..< 5 {
            await advanceMainRunLoop()
        }
        harness.undoManager.endUndoGrouping()
        harness.undoManager.groupsByEvent = groupsByEvent
        for _ in 0 ..< 2 {
            await advanceMainRunLoop()
        }

        #expect(harness.undoManager.canUndo)
        harness.undoManager.undo()
        #expect(textView.text == "本文")
        #expect(harness.changes.received.last == "本文")
    }

    @available(iOS 26.0, *)
    @Test("IME確定に使われただけのReturnへ字下げを誤適用しない")
    func imeCommitReturnWithoutNewlineDoesNotIndent() async {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0))

        let shouldApplySystemChange = harness.coordinator.textView(
            textView,
            shouldChangeTextInRanges: [NSValue(range: NSRange(location: 2, length: 1))],
            replacementText: "\n"
        )
        #expect(shouldApplySystemChange)
        harness.coordinator.textViewDidChange(textView)

        textView.unmarkText()
        for _ in 0 ..< 2 {
            await advanceMainRunLoop()
        }

        #expect(textView.text == "本文仮")
        #expect(textView.selectedRange == NSRange(location: 3, length: 0))
        #expect(harness.changes.received.last == "本文仮")
    }

    @available(iOS 26.0, *)
    @Test("IME中に確定した裸の改行にもR1′の全角スペースを一度だけ補う")
    func imeNewlineCommitUsesCurrentIndentRules() async {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0))

        let shouldApplySystemChange = harness.coordinator.textView(
            textView,
            shouldChangeTextInRanges: [NSValue(range: NSRange(location: 2, length: 1))],
            replacementText: "\n"
        )
        #expect(shouldApplySystemChange)

        // UIKitがmarked textを裸の改行へ更新した状態を再現する。
        textView.setMarkedText("\n", selectedRange: NSRange(location: 1, length: 0))
        harness.coordinator.textViewDidChange(textView)
        #expect(harness.changes.received.isEmpty)

        textView.unmarkText()
        for _ in 0 ..< 6 {
            await advanceMainRunLoop()
        }

        #expect(textView.text == "本文\n　")
        #expect(textView.selectedRange == NSRange(location: 4, length: 0))
        #expect(harness.changes.received.last == "本文\n　")

        harness.undoManager.undo()
        #expect(textView.text == "本文\n")
        harness.undoManager.redo()
        #expect(textView.text == "本文\n　")
    }
}
#endif
