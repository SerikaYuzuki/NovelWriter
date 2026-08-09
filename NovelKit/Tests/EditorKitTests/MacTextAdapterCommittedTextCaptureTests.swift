#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

@MainActor
struct MacTextAdapterCommittedTextCaptureTests {
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
