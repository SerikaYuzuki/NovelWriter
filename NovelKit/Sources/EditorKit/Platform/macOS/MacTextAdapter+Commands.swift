#if canImport(AppKit)
import AppKit

extension MacTextAdapter.Coordinator {
    /// SwiftUIからの明示commandを、NSTextViewの選択と正規編集経路へ接続する。
    func applyEditorCommandIfNeeded(
        _ command: EditorCommand?,
        session: EditorCommandSession,
        textView: NSTextView
    ) {
        guard let command else { return }
        guard session.canHandleCommand(id: command.id, on: commandSurfaceToken) else { return }
        guard !textView.hasMarkedText() else {
            session.rejectCommand(id: command.id, on: commandSurfaceToken)
            return
        }

        switch command {
        case let .requestSelectionSnapshot(id):
            let range = textView.selectedRange()
            guard let stringRange = Range(range, in: textView.string) else {
                session.rejectCommand(id: id, on: commandSurfaceToken)
                return
            }
            session.receiveSelectionSnapshot(
                EditorSelectionSnapshot(id: id, text: String(textView.string[stringRange]), range: range),
                from: commandSurfaceToken
            )
        case let .replaceSelection(id, text):
            guard let snapshot = session.selectionSnapshot, snapshot.id == id else {
                session.rejectCommand(id: id, on: commandSurfaceToken)
                return
            }
            guard textView.selectedRange() == snapshot.range else {
                session.rejectCommand(id: id, on: commandSurfaceToken)
                return
            }
            guard let stringRange = Range(snapshot.range, in: textView.string) else {
                session.rejectCommand(id: id, on: commandSurfaceToken)
                return
            }
            guard String(textView.string[stringRange]) == snapshot.text else {
                session.rejectCommand(id: id, on: commandSurfaceToken)
                return
            }

            guard applyInternalReplacement(
                range: snapshot.range,
                text: text,
                caretOffset: (text as NSString).length,
                textView: textView
            ) else {
                session.rejectCommand(id: id, on: commandSurfaceToken)
                return
            }

            session.completeCommand(id: id, on: commandSurfaceToken)
            notifyCommittedText(from: textView)
        }
    }
}
#endif
