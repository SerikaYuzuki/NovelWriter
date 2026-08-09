#if canImport(UIKit) && !canImport(AppKit)
import UIKit

extension IOSTextAdapter.Coordinator {
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard !isApplyingPluginReplacement else { return true }

        // iOSのIMEもmarked rangeを保持したまま確定入力へ入る場合がある。
        // 確定前に記録し、marked range解放後だけD-055のR5を適用する。
        if textView.markedTextRange != nil {
            hasPendingIMECommit = true
        }

        let action = pipeline.shouldChange(
            context: IOSEditorContext(textView: textView),
            range: range,
            replacement: text
        )
        switch action {
        case .allow, .allowSkippingRemaining:
            return true
        case let .replace(replacementRange, replacementText, caretOffset):
            applyPluginReplacement(
                range: replacementRange,
                text: replacementText,
                caretOffset: caretOffset,
                textView: textView
            )
            return false
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        advanceAIContentRevision()

        if isApplyingPluginReplacement {
            observedInternalTextChange = true
            return
        }
        guard TextOwnershipPolicy.shouldNotifyTextChange(
            hasMarkedText: textView.markedTextRange != nil
        ) else {
            hasPendingIMECommit = true
            return
        }
        guard !isPerformingUndoOrRedo else { return }

        synchronizeCommittedText(from: textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        advanceAISelectionRevision()
        onSelectionChange?(textView.selectedRange, commandSurfaceToken)

        // 実IMEが本文変更通知時にはまだmarked rangeを持ち、その直後の選択通知で
        // 確定する経路を取りこぼさない。pendingがある場合だけ最終同期する。
        let shouldSynchronizeIMECommit = hasPendingIMECommit &&
            textView.markedTextRange == nil &&
            !isApplyingPluginReplacement &&
            !isPerformingUndoOrRedo
        if shouldSynchronizeIMECommit {
            synchronizeCommittedText(from: textView)
        }
    }

    func prepareForDocumentTransition() -> Bool {
        advanceAISelectionSurface()
        guard let textView else { return true }
        if textView.markedTextRange != nil {
            hasPendingIMECommit = true
            textView.unmarkText()
        }
        guard textView.markedTextRange == nil else { return false }
        synchronizeCommittedText(from: textView)
        textView.isEditable = false
        return true
    }

    func resumeAfterDocumentTransition() {
        textView?.isEditable = true
    }

    func notifyCommittedText(from textView: UITextView) {
        guard textView.markedTextRange == nil, !isApplyingPluginReplacement else { return }
        onTextChange(textView.text)
    }

    private func synchronizeCommittedText(from textView: UITextView) {
        guard textView.markedTextRange == nil, !isApplyingPluginReplacement else { return }

        pipeline.didChange(context: IOSEditorContext(textView: textView))

        if hasPendingIMECommit {
            hasPendingIMECommit = false
            applyPostIMEChange(to: textView)
        }

        notifyCommittedText(from: textView)
    }

    private func applyPostIMEChange(to textView: UITextView) {
        switch IndentRules.postChangeAction(
            in: textView.text,
            caretLocation: textView.selectedRange.location
        ) {
        case .allow:
            break
        case let .replace(range, text, caretOffset):
            _ = applyInternalReplacement(
                range: range,
                text: text,
                caretOffset: caretOffset,
                textView: textView
            )
        case let .moveCaret(location):
            textView.selectedRange = NSRange(location: location, length: 0)
            IOSViewport.reveal(range: textView.selectedRange, in: textView)
        }
    }
}
#endif
