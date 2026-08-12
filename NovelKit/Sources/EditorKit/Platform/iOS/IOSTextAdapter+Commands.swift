#if canImport(UIKit) && !canImport(AppKit)
import UIKit

extension IOSTextAdapter.Coordinator {
    /// SwiftUIからの明示commandを、現在の`UITextView` surfaceへ拘束して処理する。
    func applyEditorCommandIfNeeded(
        _ command: EditorCommand?,
        session: EditorCommandSession,
        textView: UITextView
    ) {
        guard let command else { return }
        guard session.canHandleCommand(id: command.id, on: commandSurfaceToken) else { return }
        guard textView.markedTextRange == nil else {
            session.rejectCommand(id: command.id, on: commandSurfaceToken)
            return
        }

        switch command {
        case let .requestSelectionSnapshot(id):
            captureSelectionSnapshot(id: id, session: session, textView: textView)

        case let .replaceSelection(id, text):
            replaceSelection(id: id, with: text, session: session, textView: textView)
        }
    }

    private func captureSelectionSnapshot(
        id: UUID,
        session: EditorCommandSession,
        textView: UITextView
    ) {
        let range = textView.selectedRange
        guard let stringRange = Range(range, in: textView.text) else {
            session.rejectCommand(id: id, on: commandSurfaceToken)
            return
        }
        session.receiveSelectionSnapshot(
            EditorSelectionSnapshot(
                id: id,
                text: String(textView.text[stringRange]),
                range: range
            ),
            from: commandSurfaceToken
        )
    }

    private func replaceSelection(
        id: UUID,
        with text: String,
        session: EditorCommandSession,
        textView: UITextView
    ) {
        guard let snapshot = validatedSelectionSnapshot(id: id, session: session, textView: textView) else {
            session.rejectCommand(id: id, on: commandSurfaceToken)
            return
        }
        let didReplace = applyInternalReplacement(
            range: snapshot.range,
            text: text,
            caretOffset: (text as NSString).length,
            textView: textView
        )
        guard didReplace else {
            session.rejectCommand(id: id, on: commandSurfaceToken)
            return
        }

        session.completeCommand(id: id, on: commandSurfaceToken)
        notifyCommittedText(from: textView)
    }

    private func validatedSelectionSnapshot(
        id: UUID,
        session: EditorCommandSession,
        textView: UITextView
    ) -> EditorSelectionSnapshot? {
        guard let snapshot = session.selectionSnapshot, snapshot.id == id else { return nil }
        guard textView.selectedRange == snapshot.range else { return nil }
        guard let stringRange = Range(snapshot.range, in: textView.text) else { return nil }
        guard String(textView.text[stringRange]) == snapshot.text else { return nil }
        return snapshot
    }
}
#endif
