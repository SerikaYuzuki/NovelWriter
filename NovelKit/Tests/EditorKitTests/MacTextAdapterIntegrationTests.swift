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

    @Test("active editor surfaceがない選択取得要求は即時拒否する")
    func selectionRequestWithoutActiveSurfaceIsRejected() {
        let session = EditorCommandSession()

        let commandID = session.requestSelectionSnapshot()

        #expect(!session.hasActiveEditorSurface)
        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
    }

    @Test("作品遷移前はIMEを旧本文へ確定し、保存完了まで入力を停止する")
    func documentTransitionCommitsIMEAndLocksEditor() {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerDocumentLifecycle(with: session)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        beginIMEComposition(in: textView)

        #expect(textView.hasMarkedText())
        #expect(harness.changes.received.isEmpty)
        #expect(session.prepareForDocumentTransition())

        #expect(!textView.hasMarkedText())
        #expect(harness.changes.received.last == textView.string)
        #expect(!textView.isEditable)
        #expect(session.isDocumentTransitionPrepared)

        session.resumeAfterDocumentTransition()
        #expect(textView.isEditable)
        #expect(!session.isDocumentTransitionPrepared)
    }

    @Test("作品遷移は処理中のEditor commandを旧作品側で拒否する")
    func documentTransitionRejectsPendingCommand() {
        let harness = makeHarness(initialText: "本文")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        let commandID = session.requestSelectionSnapshot()
        #expect(session.pendingCommand?.id == commandID)

        #expect(session.prepareForDocumentTransition())

        #expect(session.pendingCommand == nil)
        #expect(session.rejectedCommandID == commandID)
    }

    @Test("作品遷移は取得済み選択を破棄し、再開後も旧transactionを復活させない")
    func documentTransitionInvalidatesCapturedSelectionTransaction() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerDocumentLifecycle(with: session)
        harness.coordinator.registerCommandSurface(with: session)
        textView.setSelectedRange(NSRange(location: 0, length: 1))

        let commandID = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )
        _ = try #require(session.selectionSnapshot)

        #expect(session.prepareForDocumentTransition())
        #expect(session.selectionSnapshot == nil)
        #expect(session.pendingCommand == nil)
        #expect(session.rejectedCommandID == commandID)

        session.resumeAfterDocumentTransition()
        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
        #expect(textView.string == "猫と犬")
    }

    @Test("旧surfaceのsnapshotは同じ範囲・同じ本文でも新surfaceへ適用しない")
    func surfaceSwitchInvalidatesSelectionTransaction() throws {
        let oldSurface = makeHarness(initialText: "猫と犬")
        let newSurface = makeHarness(initialText: "猫と犬")
        let session = EditorCommandSession()
        let selectedRange = NSRange(location: 0, length: 1)

        oldSurface.coordinator.registerCommandSurface(with: session)
        oldSurface.textView.setSelectedRange(selectedRange)
        let commandID = session.requestSelectionSnapshot()
        oldSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: oldSurface.textView
        )
        _ = try #require(session.selectionSnapshot)

        newSurface.textView.setSelectedRange(selectedRange)
        newSurface.coordinator.registerCommandSurface(with: session)
        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        newSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: newSurface.textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
        #expect(oldSurface.textView.string == "猫と犬")
        #expect(newSurface.textView.string == "猫と犬")
        #expect(newSurface.changes.received.isEmpty)
    }

    @Test("旧surfaceの遅延advance・再登録・破棄後も新surfaceがcommandを処理できる")
    func staleSurfaceReregistrationCannotReclaimActiveSession() throws {
        let oldSurface = makeHarness(initialText: "猫と犬")
        let newSurface = makeHarness(initialText: "猫と犬")
        let session = EditorCommandSession()
        let selectedRange = NSRange(location: 0, length: 1)

        oldSurface.coordinator.registerCommandSurface(with: session)
        newSurface.coordinator.registerCommandSurface(with: session)
        oldSurface.coordinator.advanceCommandSurface()
        oldSurface.coordinator.registerCommandSurface(with: session)
        oldSurface.coordinator.unregisterCommandSurface()

        newSurface.textView.setSelectedRange(selectedRange)
        let commandID = session.requestSelectionSnapshot()
        newSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: newSurface.textView
        )
        _ = try #require(session.selectionSnapshot)

        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        newSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: newSurface.textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == nil)
        #expect(oldSurface.textView.string == "猫と犬")
        #expect(newSurface.textView.string == "｜猫《ねこ》と犬")
        #expect(newSurface.changes.received == ["｜猫《ねこ》と犬"])
    }

    @Test("active surface破棄後は以前のsurfaceがsessionを再claimしてcommandを処理できる")
    func priorSurfaceCanReclaimUnownedSession() throws {
        let priorSurface = makeHarness(initialText: "猫と犬")
        let activeSurface = makeHarness(initialText: "猫と犬")
        let session = EditorCommandSession()
        let selectedRange = NSRange(location: 0, length: 1)

        priorSurface.coordinator.registerCommandSurface(with: session)
        activeSurface.coordinator.registerCommandSurface(with: session)
        activeSurface.coordinator.unregisterCommandSurface()
        #expect(!session.hasActiveEditorSurface)

        priorSurface.coordinator.registerCommandSurface(with: session)
        #expect(session.hasActiveEditorSurface)
        priorSurface.textView.setSelectedRange(selectedRange)
        let commandID = session.requestSelectionSnapshot()
        priorSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: priorSurface.textView
        )
        _ = try #require(session.selectionSnapshot)

        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        priorSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: priorSurface.textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == nil)
        #expect(priorSurface.textView.string == "｜猫《ねこ》と犬")
        #expect(priorSurface.changes.received == ["｜猫《ねこ》と犬"])
        #expect(activeSurface.textView.string == "猫と犬")
    }

    @Test("旧Coordinatorはsurfaceとlifecycleの解放後に両leaseを再claimできる")
    func priorCoordinatorReclaimsSurfaceAndLifecycleLeases() {
        let priorSurface = makeHarness(initialText: "旧本文")
        let activeSurface = makeHarness(initialText: "新本文")
        let session = EditorCommandSession()

        priorSurface.coordinator.registerDocumentLifecycle(with: session)
        priorSurface.coordinator.registerCommandSurface(with: session)
        activeSurface.coordinator.registerDocumentLifecycle(with: session)
        activeSurface.coordinator.registerCommandSurface(with: session)

        activeSurface.coordinator.unregisterCommandSurface()
        activeSurface.coordinator.unregisterDocumentLifecycle()
        #expect(!session.hasActiveEditorSurface)

        priorSurface.coordinator.registerDocumentLifecycle(with: session)
        priorSurface.coordinator.registerCommandSurface(with: session)
        #expect(session.hasActiveEditorSurface)

        let textView = priorSurface.textView
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        beginIMEComposition(in: textView)
        #expect(textView.hasMarkedText())

        #expect(session.prepareForDocumentTransition())

        #expect(!textView.hasMarkedText())
        #expect(priorSurface.changes.received.last == textView.string)
        #expect(!textView.isEditable)
        #expect(activeSurface.textView.isEditable)
        #expect(activeSurface.changes.received.isEmpty)
        #expect(session.isDocumentTransitionPrepared)
    }

    @Test("新surface切替後の旧surface selection eventはavailabilityを変更しない")
    func staleSurfaceSelectionEventDoesNotChangeAvailability() {
        let oldSurface = makeHarness(initialText: "猫と犬")
        let newSurface = makeHarness(initialText: "猫と犬")
        let session = EditorCommandSession()

        oldSurface.coordinator.registerCommandSurface(with: session)
        session.updateSelectionAvailability(
            NSRange(location: 0, length: 1),
            from: oldSurface.coordinator.commandSurfaceToken
        )
        #expect(session.hasNonEmptySelection)

        newSurface.coordinator.registerCommandSurface(with: session)
        #expect(!session.hasNonEmptySelection)
        session.updateSelectionAvailability(
            NSRange(location: 0, length: 1),
            from: oldSurface.coordinator.commandSurfaceToken
        )
        #expect(!session.hasNonEmptySelection)

        session.updateSelectionAvailability(
            NSRange(location: 0, length: 1),
            from: newSurface.coordinator.commandSurfaceToken
        )
        #expect(session.hasNonEmptySelection)
    }

    @Test("同じCoordinatorで話を切り替えると旧snapshotを同じ範囲・同じ本文にも適用しない")
    func chapterSwitchInvalidatesSelectionTransaction() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let textView = harness.textView
        let session = EditorCommandSession()
        let selectedRange = NSRange(location: 0, length: 1)

        harness.coordinator.registerCommandSurface(with: session)
        textView.setSelectedRange(selectedRange)
        let commandID = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )
        _ = try #require(session.selectionSnapshot)

        harness.coordinator.advanceCommandSurface()
        textView.setSelectedRange(selectedRange)
        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
        #expect(textView.string == "猫と犬")
        #expect(harness.changes.received.isEmpty)
    }

    @Test("Adapter破棄後は旧surfaceのsnapshotを適用しない")
    func dismantledSurfaceInvalidatesSelectionTransaction() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let textView = harness.textView
        let session = EditorCommandSession()

        harness.coordinator.registerCommandSurface(with: session)
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        session.updateSelectionAvailability(
            textView.selectedRange(),
            from: harness.coordinator.commandSurfaceToken
        )
        #expect(session.hasActiveEditorSurface)
        #expect(session.hasNonEmptySelection)
        let commandID = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )
        _ = try #require(session.selectionSnapshot)

        harness.coordinator.unregisterCommandSurface()
        #expect(!session.hasActiveEditorSurface)
        #expect(!session.hasNonEmptySelection)
        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
        #expect(textView.string == "猫と犬")
        #expect(harness.changes.received.isEmpty)
    }

    @Test("作品遷移中に発行されたEditor commandは即時拒否する")
    func documentTransitionRejectsCommandsIssuedWhilePrepared() {
        let harness = makeHarness(initialText: "本文")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        #expect(session.prepareForDocumentTransition())

        let requestID = session.requestSelectionSnapshot()
        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == requestID)

        session.replaceSelection(id: requestID, text: "……")
        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == requestID)
    }

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
