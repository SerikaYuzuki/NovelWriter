#if canImport(AppKit)
import AppKit

@MainActor
private final class EditorSelectionContextMenuActionBox: NSObject {
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

extension MacTextAdapter.Coordinator {
    /// NSTextViewの標準menuを保持したまま、App層が渡した選択範囲commandを末尾へ追加する。
    ///
    /// 右クリック位置がexactなnonempty selection内にあり、IME変換中でなく、UTF-16範囲を
    /// Swiftの`String.Range`へ変換できる場合だけcommandを有効にする。menu表示後にも
    /// surface／revision／range／sourceを再検査し、古いsnapshotの実行を拒否する。
    func textView(
        _ view: NSTextView,
        menu standardMenu: NSMenu,
        for _: NSEvent,
        at charIndex: Int
    ) -> NSMenu? {
        guard !selectionContextMenuCommands.isEmpty else { return standardMenu }

        let menu = (standardMenu.copy() as? NSMenu) ?? standardMenu
        let snapshot = selectionContextMenuSnapshot(in: view, clickedCharacterIndex: charIndex)

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        for command in selectionContextMenuCommands {
            let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
            if let systemImageName = command.systemImageName {
                item.image = NSImage(
                    systemSymbolName: systemImageName,
                    accessibilityDescription: command.title
                )
            }

            if let snapshot {
                item.target = self
                item.action = #selector(performSelectionContextMenuCommand(_:))
                item.representedObject = EditorSelectionContextMenuActionBox(
                    command: command,
                    snapshot: snapshot,
                    surfaceToken: commandSurfaceToken,
                    contentRevision: aiContentRevision,
                    selectionRevision: aiSelectionRevision
                )
                item.isEnabled = true
            } else {
                // target/actionを空にして、NSMenuのauto-enableでも有効化されないようにする。
                item.target = nil
                item.action = nil
                item.isEnabled = false
            }
            menu.addItem(item)
        }

        return menu
    }

    @objc private func performSelectionContextMenuCommand(_ sender: NSMenuItem) {
        guard ownsActiveCommandSurface(),
              let box = sender.representedObject as? EditorSelectionContextMenuActionBox,
              box.surfaceToken == commandSurfaceToken,
              box.contentRevision == aiContentRevision,
              box.selectionRevision == aiSelectionRevision,
              let textView,
              !textView.hasMarkedText(),
              textView.selectedRange() == box.snapshot.range,
              let stringRange = Range(box.snapshot.range, in: textView.string),
              String(textView.string[stringRange]) == box.snapshot.text else { return }

        box.command.perform(with: box.snapshot)
    }

    private func selectionContextMenuSnapshot(
        in textView: NSTextView,
        clickedCharacterIndex: Int
    ) -> EditorSelectionContextMenuSnapshot? {
        guard ownsActiveCommandSurface(), !textView.hasMarkedText() else { return nil }

        let range = textView.selectedRange()
        guard range.length > 0,
              let stringRange = Range(range, in: textView.string),
              clickedCharacterIndex >= range.location,
              clickedCharacterIndex < NSMaxRange(range) else { return nil }

        return EditorSelectionContextMenuSnapshot(
            text: String(textView.string[stringRange]),
            range: range
        )
    }
}
#endif
