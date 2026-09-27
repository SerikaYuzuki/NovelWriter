#if canImport(AppKit)
import AppKit

extension MacTextAdapter.Coordinator {
    /// plugin / command / Undoが確定した最終本文だけをモデルへ渡す。
    /// 通常入力向けのpipelineやR5後処理は再実行しない。
    func notifyCommittedText(from textView: NSTextView) {
        guard !textView.hasMarkedText(), !isApplyingPluginReplacement else { return }
        refreshProofreadingHighlights(textView)
        onTextChange(textView.string)
    }

    func refreshProofreadingHighlights(_ textView: NSTextView, clearing: Bool = false) {
        guard proofreadingOriginal != nil || clearing else { return }
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes.removeValue(forKey: .backgroundColor)
        guard let proofreadingOriginal else { return }
        for range in ProofreadingChanges.insertedRanges(original: proofreadingOriginal, revised: textView.string) {
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.28), range: range)
        }
    }

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
