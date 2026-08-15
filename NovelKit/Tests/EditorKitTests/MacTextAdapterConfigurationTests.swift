#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

extension MacTextAdapterIntegrationTests {
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
}
#endif
