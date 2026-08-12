#if canImport(UIKit) && !canImport(AppKit)
import UIKit

@MainActor
final class IOSSelectionContextMenuActionBox {
    let command: EditorSelectionContextMenuCommand
    let snapshot: EditorSelectionContextMenuSnapshot
    let surfaceToken: EditorSurfaceToken
    let contentRevision: UInt64
    let selectionRevision: UInt64

    init(
        command: EditorSelectionContextMenuCommand,
        snapshot: EditorSelectionContextMenuSnapshot,
        surfaceToken: EditorSurfaceToken,
        contentRevision: UInt64,
        selectionRevision: UInt64
    ) {
        self.command = command
        self.snapshot = snapshot
        self.surfaceToken = surfaceToken
        self.contentRevision = contentRevision
        self.selectionRevision = selectionRevision
    }
}

extension IOSTextAdapter.Coordinator {
    /// iOS標準の選択menuを保持し、その末尾へApp層の選択commandを追加する。
    ///
    /// menu生成時とaction実行時の二度、active surface、IME、UTF-16範囲、exact本文を
    /// 検査する。本文やUndo履歴は変更しない。
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard !selectionContextMenuCommands.isEmpty else { return nil }

        let snapshot = selectionContextMenuSnapshot(in: textView, menuRange: range)
        let customActions = selectionContextMenuCommands.map { command in
            let box = snapshot.map {
                IOSSelectionContextMenuActionBox(
                    command: command,
                    snapshot: $0,
                    surfaceToken: commandSurfaceToken,
                    contentRevision: aiContentRevision,
                    selectionRevision: aiSelectionRevision
                )
            }
            let attributes: UIMenuElement.Attributes = box == nil ? .disabled : []
            return UIAction(
                title: command.title,
                image: command.systemImageName.flatMap(UIImage.init(systemName:)),
                attributes: attributes
            ) { [weak self, box] _ in
                guard let box else { return }
                self?.performSelectionContextMenuCommand(box)
            }
        }

        let commandsMenu = UIMenu(options: .displayInline, children: customActions)
        return UIMenu(children: suggestedActions + [commandsMenu])
    }

    func performSelectionContextMenuCommand(_ box: IOSSelectionContextMenuActionBox) {
        guard ownsActiveCommandSurface(),
              box.surfaceToken == commandSurfaceToken,
              box.contentRevision == aiContentRevision,
              box.selectionRevision == aiSelectionRevision,
              let textView,
              textView.markedTextRange == nil,
              textView.selectedRange == box.snapshot.range,
              let stringRange = Range(box.snapshot.range, in: textView.text),
              String(textView.text[stringRange]) == box.snapshot.text else { return }

        box.command.perform(with: box.snapshot)
    }

    func selectionContextMenuSnapshot(
        in textView: UITextView,
        menuRange: NSRange
    ) -> EditorSelectionContextMenuSnapshot? {
        guard ownsActiveCommandSurface(), textView.markedTextRange == nil else { return nil }

        let selection = textView.selectedRange
        guard selection.length > 0,
              selection == menuRange,
              let stringRange = Range(selection, in: textView.text) else { return nil }

        return EditorSelectionContextMenuSnapshot(
            text: String(textView.text[stringRange]),
            range: selection
        )
    }
}
#endif
