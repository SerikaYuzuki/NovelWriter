#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

@MainActor
struct EditorViewportTests {
    @Test("本文を変えず、下端に執筆用の表示余白を確保する")
    func configurationAddsDisplayOnlyBottomClearance() throws {
        let scrollView = NSTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? NSTextView)
        textView.string = "本文"

        EditorViewport.configure(scrollView: scrollView, textView: textView)

        #expect(textView.string == "本文")
        #expect(textView.textContainerInset == NSSize(width: 16, height: 16))
        #expect(!scrollView.contentView.automaticallyAdjustsContentInsets)
        #expect(scrollView.contentView.contentInsets.top == 0)
        #expect(scrollView.contentView.contentInsets.left == 0)
        #expect(scrollView.contentView.contentInsets.bottom == 96)
        #expect(scrollView.contentView.contentInsets.right == 0)
    }

    @Test("本文末尾より下へ96ptスクロールできる")
    func bottomClearanceExtendsScrollableAreaBeyondDocument() throws {
        let scrollView = NSTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? NSTextView)
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        EditorViewport.configure(scrollView: scrollView, textView: textView)
        scrollView.tile()

        let longText = (0 ..< 40).map { "\($0) 本文" }.joined(separator: "\n")
        textView.string = longText
        let textLayoutManager = try #require(textView.textLayoutManager)
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        textView.setSelectedRange(NSRange(location: (longText as NSString).length, length: 0))

        EditorViewport.revealCaret(in: textView)

        #expect(scrollView.documentVisibleRect.minY > 0)
        #expect(abs(
            scrollView.documentVisibleRect.maxY
                - textView.frame.maxY
                - EditorViewport.bottomWritingClearance
        ) < 0.5)
    }

    @Test("プラグイン置換で移動したキャレットを明示的に表示する")
    func pluginReplacementRevealsMovedCaret() {
        let textView = CaretTrackingTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 16)]
        textView.string = "本文"

        let coordinator = MacTextAdapter.Coordinator(onTextChange: { _ in })
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        let handled = coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange(),
            replacementString: "\n"
        )

        #expect(!handled)
        #expect(textView.string == "本文\n　")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
        #expect(textView.revealedRanges.last == NSRange(location: 4, length: 0))
    }
}

@MainActor
private final class CaretTrackingTextView: NSTextView {
    var revealedRanges: [NSRange] = []

    override func scrollRangeToVisible(_ range: NSRange) {
        revealedRanges.append(range)
    }
}
#endif
