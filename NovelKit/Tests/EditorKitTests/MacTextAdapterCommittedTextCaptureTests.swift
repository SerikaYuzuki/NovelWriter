#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

@MainActor
struct MacTextAdapterCommittedTextCaptureTests {
    @MainActor
    private final class Changes {
        var received: [String] = []
    }

    private struct Harness {
        let textView: NSTextView
        let coordinator: MacTextAdapter.Coordinator
        let changes: Changes
    }

    private func makeHarness(initialText: String) -> Harness {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.string = initialText

        let changes = Changes()
        let coordinator = MacTextAdapter.Coordinator(onTextChange: { changes.received.append($0) })
        coordinator.textView = textView
        textView.delegate = coordinator
        return Harness(textView: textView, coordinator: coordinator, changes: changes)
    }

    @Test("active surfaceがなければ確定全文captureはnotActiveを返す")
    func captureWithoutActiveSurfaceIsNotActive() {
        let session = EditorCommandSession()

        #expect(session.captureActiveCommittedText() == .notActive)
    }

    @Test("active surfaceからTextView所有の最新確定全文を読み取り専用で取得する")
    func captureReadsLatestTextViewContent() {
        let harness = makeHarness(initialText: "modelへ未通知の本文")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        harness.textView.string = "TextViewが所有する最新本文😀"
        let originalSelection = harness.textView.selectedRange()

        let result = session.captureActiveCommittedText()

        #expect(result == .captured("TextViewが所有する最新本文😀"))
        #expect(harness.textView.string == "TextViewが所有する最新本文😀")
        #expect(harness.textView.selectedRange() == originalSelection)
        #expect(!harness.coordinator.undoManager.canUndo)
        #expect(harness.changes.received.isEmpty)
    }

    @Test("IME変換中の確定全文captureはcompositionInProgressを返す")
    func captureRejectsIMEComposition() {
        let harness = makeHarness(initialText: "本文")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        harness.textView.setSelectedRange(NSRange(location: 2, length: 0))
        harness.textView.setMarkedText(
            "か",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(session.captureActiveCommittedText() == .compositionInProgress)
    }

    @Test("surface切替と破棄後も確定全文captureのownerを取り違えない")
    func captureFollowsActiveSurfaceOwnership() {
        let oldSurface = makeHarness(initialText: "旧本文")
        let newSurface = makeHarness(initialText: "新本文")
        let session = EditorCommandSession()

        oldSurface.coordinator.registerCommandSurface(with: session)
        #expect(session.captureActiveCommittedText() == .captured("旧本文"))

        newSurface.coordinator.registerCommandSurface(with: session)
        #expect(session.captureActiveCommittedText() == .captured("新本文"))

        // 旧Coordinatorの遅延update／破棄は、新ownerのhandlerを奪取・解除しない。
        oldSurface.coordinator.registerCommandSurface(with: session)
        oldSurface.coordinator.unregisterCommandSurface()
        #expect(session.captureActiveCommittedText() == .captured("新本文"))

        newSurface.coordinator.unregisterCommandSurface()
        #expect(session.captureActiveCommittedText() == .notActive)
    }

    @Test("同じCoordinatorの本文surface更新後も新しいownerから確定全文を取得する")
    func captureRebindsAfterSurfaceAdvance() {
        let harness = makeHarness(initialText: "第一話")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)

        harness.coordinator.advanceCommandSurface()
        harness.textView.string = "第二話"

        #expect(session.captureActiveCommittedText() == .captured("第二話"))
    }
}
#endif
#if canImport(AppKit)
extension MacTextAdapterCommittedTextCaptureTests {
    @Test("長い校正を反映しても修正箇所だけ着色し、Undo・Redo・色の解除を保つ")
    func distantProofreadingHighlights() throws {
        let unchanged = String(repeating: "変わらない本文。\n", count: 300)
        let original = "前誤\n" + unchanged + "字後"
        let revised = "前正\n" + unchanged + "文後"
        let harness = makeHarness(initialText: original)
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        let storage = try #require(harness.textView.textStorage)
        func highlights() -> [NSRange] {
            var ranges: [NSRange] = []
            storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value != nil {
                    ranges.append(range)
                }
            }
            return ranges
        }
        let expected = [NSRange(location: 1, length: 1), NSRange(location: 3 + unchanged.utf16.count, length: 1)]
        #expect(session.applyProofreading(expectedText: original, replacement: revised))
        #expect(highlights() == expected)
        #expect(harness.textView.string == revised)
        #expect(harness.textView.typingAttributes[.backgroundColor] == nil)
        harness.coordinator.undoManager.undo()
        #expect(harness.textView.string == original)
        #expect(highlights().isEmpty)
        harness.coordinator.undoManager.redo()
        #expect(highlights() == expected)
        session.clearProofreadingHighlights()
        #expect(highlights().isEmpty)
        #expect(harness.textView.string == revised)
    }

    @Test("色付けがない保存では本文属性を変更せず、再レイアウトを発生させない", arguments: [false, true])
    func clearingAbsentHighlightsDoesNotEditStorage(afterProofreading: Bool) {
        let harness = makeHarness(initialText: "猫が歩く。")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        if afterProofreading {
            #expect(session.applyProofreading(expectedText: "猫が歩く。", replacement: "猫が走る。"))
            session.clearProofreadingHighlights()
        }
        let edits = Changes()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: harness.textView.textStorage,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { edits.received.append("storage edited") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        session.clearProofreadingHighlights()
        session.clearProofreadingHighlights()
        #expect(edits.received.isEmpty)
    }

    @Test("proofreading preserves native Undo, rejects stale text and IME, and clears only presentation")
    func proofreadingBoundary() {
        let harness = makeHarness(initialText: "猫が歩く。")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        let textView = harness.textView
        #expect(!session.applyProofreading(expectedText: "古い本文", replacement: "変更"))
        #expect(session.applyProofreading(expectedText: "猫が歩く。", replacement: "猫が走る。"))
        #expect(textView.string == "猫が走る。")
        #expect(textView.textStorage?.attribute(.backgroundColor, at: 2, effectiveRange: nil) != nil)
        #expect(textView.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(harness.changes.received.last == "猫が走る。")
        harness.coordinator.undoManager.undo()
        #expect(textView.string == "猫が歩く。")
        harness.coordinator.undoManager.redo()
        #expect(textView.string == "猫が走る。")
        session.clearProofreadingHighlights()
        #expect(textView.string == "猫が走る。")
        #expect(textView.textStorage?.attribute(.backgroundColor, at: 2, effectiveRange: nil) == nil)
        textView.setMarkedText(
            "か",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        #expect(!session.applyProofreading(expectedText: textView.string, replacement: "変更"))
    }
}
#endif
