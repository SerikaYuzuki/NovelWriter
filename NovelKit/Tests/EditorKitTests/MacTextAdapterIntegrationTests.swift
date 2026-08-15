// `MacTextAdapter` は internal 型であり、macOS(AppKit)専用の実装(docs/DESIGN.md 9.2)。
// iOS 向けコンパイルチェック(D-013)を壊さないよう、このテストファイル自体も
// `#if canImport(AppKit)` で保護する。
#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

/// `MacTextAdapter.Coordinator`(docs/DESIGN.md 4.3, 4.4)の統合テスト。
///
/// SwiftUI の `NSViewRepresentable.Context` はテストから直接構築できないため、
/// `makeNSView` を経由せず、実 `NSTextView` + `Coordinator` を直接組み立てて
/// `NSTextViewDelegate` の実装(`textView(_:shouldChangeTextIn:replacementString:)`)を
/// 直接駆動するテストに加え、実 `insertText` とmarked rangeを使ってAppKitの通常入力・
/// IME確定経路も駆動する。ヘッドレスな環境でもproductionの入力通知順、プラグイン、
/// undo登録、textStorage書き換えをまとめて検証する。
@MainActor
struct MacTextAdapterIntegrationTests {
    @Test("Enter: 「\\n + 全角スペース」が挿入され、キャレットが直後に来る")
    func enterInsertsIndentAfterNewline() {
        let harness = makeHarness(initialText: "こんにちは")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        let handled = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\n"
        )

        #expect(!handled)
        #expect(textView.string == "こんにちは\n\u{3000}")
        #expect(textView.selectedRange() == NSRange(location: (textView.string as NSString).length, length: 0))
        #expect(harness.changes.received == ["こんにちは\n\u{3000}"])
    }

    @Test("空白のみの行でEnter: 空白を掃除せず、新しい行にも字下げする")
    func enterOnWhitespaceOnlyLineKeepsIndent() {
        let harness = makeHarness(initialText: "本文\n　　")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        let handled = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\n"
        )

        #expect(!handled)
        #expect(textView.string == "本文\n　　\n　")
    }

    @Test("字下げ直後の行末で「を入力すると、全角スペースが鉤括弧に置き換わる")
    func bracketReplacesIndentSpace() {
        let harness = makeHarness(initialText: "\u{3000}")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        let handled = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "「"
        )

        #expect(!handled)
        #expect(textView.string == "「")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test("字下げ直後の行末で「」を入力すると、全角スペースが消えてキャレットが括弧内に来る")
    func bracketPairReplacesIndentSpaceAndKeepsCaretInside() {
        let harness = makeHarness(initialText: "\u{3000}")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        let handled = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "「」"
        )

        #expect(!handled)
        #expect(textView.string == "「」")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test("字下げなしの文中で「」を入力してもキャレットが括弧内に来る")
    func bracketPairPlacesCaretInsideMidSentence() {
        let harness = makeHarness(initialText: "彼はと言った")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        let handled = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "「」"
        )

        #expect(!handled)
        #expect(textView.string == "彼は「」と言った")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))

        #expect(harness.coordinator.undoManager.canUndo)
        harness.coordinator.undoManager.undo()

        #expect(textView.string == "彼はと言った")
        #expect(harness.changes.received == ["彼は「」と言った", "彼はと言った"])
    }

    @Test("プラグインによる置換後、Undoで置換前の本文に戻る")
    func undoRevertsPluginReplacement() {
        let harness = makeHarness(initialText: "こんにちは")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        let handled = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\n"
        )
        #expect(!handled)
        #expect(textView.string == "こんにちは\n\u{3000}")
        #expect(harness.changes.received == ["こんにちは\n\u{3000}"])

        #expect(harness.coordinator.undoManager.canUndo)
        harness.coordinator.undoManager.undo()

        #expect(textView.string == "こんにちは")
        #expect(harness.changes.received == ["こんにちは\n\u{3000}", "こんにちは"])
    }

    @Test("Editor commandは選択範囲を置換し、Undo一回で戻せる")
    func editorCommandReplacesSelectionAndSupportsSingleUndo() throws {
        let harness = makeHarness(initialText: "本文を選択")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        let selectedRange = NSRange(location: 3, length: 1)
        textView.setSelectedRange(selectedRange)

        let id = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)
        let snapshot = try #require(session.selectionSnapshot)
        #expect(snapshot.id == id)
        #expect(snapshot.text == "選")
        #expect(snapshot.range == selectedRange)

        session.replaceSelection(id: id, text: "……")
        harness.coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)

        #expect(textView.string == "本文を……択")
        #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
        #expect(harness.coordinator.undoManager.canUndo)
        #expect(harness.changes.received == ["本文を……択"])

        harness.coordinator.undoManager.undo()

        #expect(textView.string == "本文を選択")
        #expect(harness.changes.received == ["本文を……択", "本文を選択"])

        #expect(harness.coordinator.undoManager.canRedo)
        harness.coordinator.undoManager.redo()

        #expect(textView.string == "本文を……択")
        #expect(harness.changes.received == ["本文を……択", "本文を選択", "本文を……択"])
    }

    @Test("Editor commandは未選択時にcaretへ挿入する")
    func editorCommandInsertsAtCaret() throws {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        let id = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)
        _ = try #require(session.selectionSnapshot)
        session.replaceSelection(id: id, text: "――")
        harness.coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)

        #expect(textView.string == "本――文")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test("Editor commandはIME変換中に本文を変更しない")
    func editorCommandIsRejectedWhileComposing() {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        beginIMEComposition(in: textView)

        let id = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)

        #expect(session.rejectedCommandID == id)
        #expect(session.selectionSnapshot == nil)
        #expect(textView.string == "本か文")
    }

    @Test("Editor commandの内部置換が失敗した場合はcompleteせずrejectする")
    func editorCommandRejectsFailedInternalReplacement() throws {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        textView.setSelectedRange(NSRange(location: 0, length: 1))

        let id = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)
        _ = try #require(session.selectionSnapshot)

        textView.isEditable = false
        session.replaceSelection(id: id, text: "原")
        harness.coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == id)
        #expect(textView.string == "本文")
        #expect(harness.changes.received.isEmpty)
    }
}
#endif
