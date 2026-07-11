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
/// 実際にAppKitが呼ぶのと同じ形で駆動する。ヘッドレスなユニットテスト環境では
/// 実際のキーイベント合成が信頼できないため、この形が最も安定して production の
/// 経路(プラグインパイプライン → undo登録 → textStorage書き換え)を検証できる。
@MainActor
struct MacTextAdapterIntegrationTests {
    /// 実 `NSTextView`(TextKit 2)+ `Coordinator` の組み立て結果。
    private struct Harness {
        let textView: NSTextView
        let coordinator: MacTextAdapter.Coordinator
        let changes: Changes
    }

    /// `onTextChange` に届いた本文を記録するための参照型ボックス。
    private final class Changes {
        var received: [String] = []
    }

    /// テスト用に実 `NSTextView`(TextKit 2)+ `Coordinator` を組み立てる。
    private func makeHarness(initialText: String) -> Harness {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 16)]
        textView.string = initialText

        let changes = Changes()
        let coordinator = MacTextAdapter.Coordinator(onTextChange: { changes.received.append($0) })
        coordinator.textView = textView
        textView.delegate = coordinator

        return Harness(textView: textView, coordinator: coordinator, changes: changes)
    }

    /// `NSTextView` にIME変換中(未確定文字列あり)の状態を作る。
    private func beginIMEComposition(in textView: NSTextView) {
        textView.setMarkedText(
            "か",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

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
    }

    @Test("空白のみの行でEnter: 行が掃除され、新しい行には字下げしない")
    func enterOnWhitespaceOnlyLineCleansIndent() {
        let harness = makeHarness(initialText: "本文\n　　")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        let handled = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\n"
        )

        #expect(!handled)
        #expect(textView.string == "本文\n\n")
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

        #expect(harness.coordinator.undoManager.canUndo)
        harness.coordinator.undoManager.undo()

        #expect(textView.string == "こんにちは")
    }

    @Test("Editor commandは選択範囲を置換し、Undo一回で戻せる")
    func editorCommandReplacesSelectionAndSupportsSingleUndo() throws {
        let harness = makeHarness(initialText: "本文を選択")
        let textView = harness.textView
        let session = EditorCommandSession()
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

        harness.coordinator.undoManager.undo()

        #expect(textView.string == "本文を選択")
    }

    @Test("Editor commandは未選択時にcaretへ挿入する")
    func editorCommandInsertsAtCaret() throws {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        let session = EditorCommandSession()
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
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        beginIMEComposition(in: textView)

        let id = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)

        #expect(session.rejectedCommandID == id)
        #expect(session.selectionSnapshot == nil)
        #expect(textView.string == "本か文")
    }

    @Test("置換挿入後もtypingAttributesのフォントが維持される")
    func typingAttributesArePreservedAfterReplacement() {
        let harness = makeHarness(initialText: "こんにちは")
        let textView = harness.textView
        let font = NSFont.systemFont(ofSize: 16)
        textView.typingAttributes = [.font: font]
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        _ = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\n"
        )

        let insertedLocation = "こんにちは\n".utf16.count
        let appliedFont = textView.textStorage?
            .attribute(.font, at: insertedLocation, effectiveRange: nil) as? NSFont
        #expect(appliedFont == font)
    }

    @Test("同一設定の再適用ではtextStorageへの属性再適用を走らせない")
    func sameConfigurationDoesNotReapplyTextStorageAttributes() {
        let harness = makeHarness(initialText: "本文")
        let configuration = EditorConfiguration()

        harness.coordinator.applyConfigurationIfNeeded(configuration, to: harness.textView)
        #expect(harness.coordinator.textStorageAttributeApplicationCount == 1)

        harness.coordinator.applyConfigurationIfNeeded(configuration, to: harness.textView)
        #expect(harness.coordinator.textStorageAttributeApplicationCount == 1)
    }

    @Test("設定した本文色がtextColorと既存本文属性に適用される")
    func textColorConfigurationAppliesToTextViewAndStorage() {
        let harness = makeHarness(initialText: "本文")
        let configuration = EditorConfiguration(textColorHex: "#E8E6DF", backgroundColorHex: "#171719")

        harness.coordinator.applyConfigurationIfNeeded(configuration, to: harness.textView)

        let appliedTextColor = harness.textView.textColor?.usingColorSpace(.sRGB)
        let storageTextColor = (harness.textView.textStorage?
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
                    .usingColorSpace(.sRGB)
        #expect(appliedTextColor?.redComponent == storageTextColor?.redComponent)
        #expect(appliedTextColor?.greenComponent == storageTextColor?.greenComponent)
        #expect(appliedTextColor?.blueComponent == storageTextColor?.blueComponent)
    }

    @Test("設定適用時のtextContainerInsetは16pt四方になる")
    func textContainerInsetMatchesStyleGuide() {
        let harness = makeHarness(initialText: "本文")
        let configuration = EditorConfiguration()

        harness.coordinator.applyConfigurationIfNeeded(configuration, to: harness.textView)

        #expect(harness.textView.textContainerInset == NSSize(width: 16, height: 16))
    }

    @Test("IME変換中の設定変更は保留し、変換終了後の再updateで適用する")
    func configurationApplicationIsDeferredWhileComposing() {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        let initialConfiguration = EditorConfiguration()
        let changedConfiguration = EditorConfiguration(fontSize: 18)

        harness.coordinator.applyConfigurationIfNeeded(initialConfiguration, to: textView)
        #expect(harness.coordinator.textStorageAttributeApplicationCount == 1)

        beginIMEComposition(in: textView)
        #expect(textView.hasMarkedText())

        harness.coordinator.applyConfigurationIfNeeded(changedConfiguration, to: textView)
        #expect(harness.coordinator.textStorageAttributeApplicationCount == 1)
        #expect(harness.coordinator.lastAppliedConfiguration == initialConfiguration)

        textView.unmarkText()
        #expect(!textView.hasMarkedText())

        harness.coordinator.applyConfigurationIfNeeded(changedConfiguration, to: textView)
        #expect(harness.coordinator.textStorageAttributeApplicationCount == 2)
        #expect(harness.coordinator.lastAppliedConfiguration == changedConfiguration)
    }

    @Test("IME変換中(setMarkedText)は、通常なら字下げを発生させる改行にも介入しない")
    func imeComposingPreventsIntervention() {
        let harness = makeHarness(initialText: "こんにちは")
        let textView = harness.textView
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        textView.setSelectedRange(end)

        beginIMEComposition(in: textView)
        #expect(textView.hasMarkedText())

        let handled = harness.coordinator.textView(textView, shouldChangeTextIn: end, replacementString: "\n")

        // IMEGuardPluginにより後続のIndentPluginは実行されず、そのまま許可される
        // (= プラグインによる本文書き換えは起きない)。
        #expect(handled)
    }

    @Test("onTextChangeは変換中でない変更で最新の全文を届ける(D-005の回帰確認)")
    func onTextChangeDeliversFullText() {
        let harness = makeHarness(initialText: "本文")
        harness.textView.string = "本文が変わった"

        harness.coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: harness.textView)
        )

        #expect(harness.changes.received == ["本文が変わった"])
    }

    @Test("onTextChangeはIME変換中(hasMarkedText)は呼ばれない")
    func onTextChangeSkippedWhileComposing() {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        beginIMEComposition(in: textView)
        #expect(textView.hasMarkedText())

        harness.coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(harness.changes.received.isEmpty)
    }
}
#endif
