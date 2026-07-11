#if canImport(AppKit)
import AppKit

/// `EditorContext`を実際の`NSTextView`の状態から作るAdapter。
///
/// プラグインへ`NSTextView`を渡さず、delegate呼び出し時点の値だけを渡す。
struct MacEditorContext: EditorContext {
    let string: String
    let isIMEComposing: Bool

    @MainActor
    init(textView: NSTextView) {
        string = textView.string
        isIMEComposing = textView.hasMarkedText()
    }

    func lineRange(at location: Int) -> NSRange {
        (string as NSString).lineRange(for: NSRange(location: location, length: 0))
    }
}
#endif
