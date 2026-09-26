#if canImport(UIKit) && !canImport(AppKit)
import UIKit

extension IOSTextAdapter.Coordinator {
    func registerProofreadingHandler(with session: EditorCommandSession) {
        session.registerProofreadingHandler(for: commandSurfaceToken, apply: { [weak self] expected, replacement in
            guard let self, let textView, textView.markedTextRange == nil, textView.isEditable,
                  textView.text == expected else { return false }
            guard expected != replacement else { return true }
            let original = proofreadingOriginal ?? expected
            guard applyInternalReplacement(range: NSRange(location: 0, length: expected.utf16.count),
                                           text: replacement, caretOffset: 0, textView: textView) else { return false }
            proofreadingOriginal = original
            notifyCommittedText(from: textView)
            return true
        }, clear: { [weak self] in
            guard let self, proofreadingOriginal != nil,
                  let textView, textView.markedTextRange == nil else { return }
            proofreadingOriginal = nil
            refreshProofreadingHighlights(textView, clearing: true)
        })
    }

    /// 表示属性だけを更新し、確定本文・native Undo・選択と表示位置を保つ。
    func refreshProofreadingHighlights(_ textView: UITextView, clearing: Bool = false) {
        guard proofreadingOriginal != nil || clearing, textView.markedTextRange == nil else { return }
        let selection = textView.selectedRange
        let offset = textView.contentOffset
        let storage = textView.textStorage
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        if let proofreadingOriginal {
            for range in ProofreadingChanges.insertedRanges(original: proofreadingOriginal, revised: textView.text) {
                storage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.28), range: range)
            }
        }
        storage.endEditing()
        textView.typingAttributes.removeValue(forKey: .backgroundColor)
        if textView.selectedRange != selection { textView.selectedRange = selection }
        if textView.contentOffset != offset { textView.setContentOffset(offset, animated: false) }
    }
}
#endif
