#if canImport(UIKit) && !canImport(AppKit)
import UIKit

/// `EditorContext`を実際の`UITextView`の状態から作るiOS Adapter。
///
/// PluginへUIKit型を渡さず、delegate呼び出し時点の本文とIME状態だけを渡す。
struct IOSEditorContext: EditorContext {
    let string: String
    let isIMEComposing: Bool

    @MainActor
    init(textView: UITextView) {
        string = textView.text
        isIMEComposing = textView.markedTextRange != nil
    }

    func lineRange(at location: Int) -> NSRange {
        (string as NSString).lineRange(for: NSRange(location: location, length: 0))
    }
}
#endif
