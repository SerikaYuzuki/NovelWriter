#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

extension MacTextAdapterIntegrationTests {
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
