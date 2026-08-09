#if canImport(AppKit)
import AppKit

/// 本文そのものを変更せず、執筆位置を見失わないための表示領域を構成する。
@MainActor
enum EditorViewport {
    static let textContainerInset = NSSize(width: 16, height: 16)
    static let bottomWritingClearance: CGFloat = 96

    static func configure(scrollView: NSScrollView, textView: NSTextView) {
        textView.textContainerInset = textContainerInset

        let clipView = scrollView.contentView
        clipView.automaticallyAdjustsContentInsets = false
        clipView.contentInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: bottomWritingClearance,
            right: 0
        )
    }

    static func revealCaret(in textView: NSTextView) {
        textView.scrollRangeToVisible(textView.selectedRange())
    }
}
#endif
