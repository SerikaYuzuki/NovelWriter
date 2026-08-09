#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

@MainActor
struct MacTextAdapterContextMenuTests {
    private final class Captures {
        var values: [EditorSelectionContextMenuSnapshot] = []
        var textChanges: [String] = []
    }

    private final class ForcedSelectionTextView: NSTextView {
        var forcedSelectionRange: NSRange?

        override func selectedRange() -> NSRange {
            forcedSelectionRange ?? super.selectedRange()
        }
    }

    private struct Harness {
        let textView: NSTextView
        let coordinator: MacTextAdapter.Coordinator
        let captures: Captures
        let session: EditorCommandSession
    }

    private func makeHarness(
        initialText: String,
        commandCount: Int = 2,
        session: EditorCommandSession = EditorCommandSession(),
        textView: NSTextView = NSTextView(usingTextLayoutManager: true)
    ) -> Harness {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.string = initialText

        let captures = Captures()
        let coordinator = MacTextAdapter.Coordinator(
            onTextChange: { captures.textChanges.append($0) }
        )
        coordinator.selectionContextMenuCommands = (0 ..< commandCount).map { index in
            EditorSelectionContextMenuCommand(
                title: index == 0 ? "校正用プロンプトをコピー" : "アドバイス用プロンプトをコピー",
                systemImageName: index == 0 ? "checkmark.bubble" : "lightbulb"
            ) { snapshot in
                captures.values.append(snapshot)
            }
        }
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.registerCommandSurface(with: session)
        return Harness(
            textView: textView,
            coordinator: coordinator,
            captures: captures,
            session: session
        )
    }

    private func makeEvent() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func makeMenu(
        harness: Harness,
        clickedCharacterIndex: Int,
        standardTitle: String = "標準コピー"
    ) throws -> NSMenu {
        let standardMenu = NSMenu()
        standardMenu.addItem(NSMenuItem(title: standardTitle, action: nil, keyEquivalent: ""))
        return try #require(harness.coordinator.textView(
            harness.textView,
            menu: standardMenu,
            for: makeEvent(),
            at: clickedCharacterIndex
        ))
    }

    private func customItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter {
            $0.title == "校正用プロンプトをコピー" ||
                $0.title == "アドバイス用プロンプトをコピー"
        }
    }

    @Test("標準context menuを保持し、任意個の選択commandを末尾へ追加する")
    func appendsCommandsWithoutReplacingStandardMenu() throws {
        let harness = makeHarness(initialText: "前😀猫後")
        let selectedRange = (harness.textView.string as NSString).range(of: "😀猫")
        harness.textView.setSelectedRange(selectedRange)

        let menu = try makeMenu(
            harness: harness,
            clickedCharacterIndex: selectedRange.location + 1
        )
        let items = customItems(in: menu)
        let separatorStates = menu.items.map(\.isSeparatorItem)
        let enabledStates = items.map(\.isEnabled)

        #expect(menu.items.first?.title == "標準コピー")
        #expect(separatorStates.contains(true))
        #expect(items.map(\.title) == ["校正用プロンプトをコピー", "アドバイス用プロンプトをコピー"])
        #expect(enabledStates == [true, true])
    }

    @Test("actionへemojiを含むexact UTF-16選択snapshotを渡し、本文とUndoを変更しない")
    func actionReceivesExactSelectionWithoutEditing() throws {
        let harness = makeHarness(initialText: "前😀猫後")
        let originalText = harness.textView.string
        let selectedRange = (originalText as NSString).range(of: "😀猫")
        harness.textView.setSelectedRange(selectedRange)
        let menu = try makeMenu(
            harness: harness,
            clickedCharacterIndex: selectedRange.location + 1
        )
        let firstCommand = try #require(customItems(in: menu).first)

        let action = try #require(firstCommand.action)
        #expect(NSApplication.shared.sendAction(action, to: firstCommand.target, from: firstCommand))

        #expect(harness.captures.values == [
            EditorSelectionContextMenuSnapshot(text: "😀猫", range: selectedRange)
        ])
        #expect(harness.textView.string == originalText)
        #expect(harness.textView.selectedRange() == selectedRange)
        #expect(!harness.coordinator.undoManager.canUndo)
        #expect(harness.captures.textChanges.isEmpty)
    }

    @Test("右クリック位置が選択範囲外なら追加commandを無効にする")
    func disablesCommandsWhenClickIsOutsideSelection() throws {
        let harness = makeHarness(initialText: "前猫後")
        harness.textView.setSelectedRange(NSRange(location: 1, length: 1))

        let menu = try makeMenu(harness: harness, clickedCharacterIndex: 0)

        #expect(customItems(in: menu).allSatisfy { !$0.isEnabled })
    }

    @Test("空選択なら追加commandを無効にする")
    func disablesCommandsForEmptySelection() throws {
        let harness = makeHarness(initialText: "本文")
        harness.textView.setSelectedRange(NSRange(location: 1, length: 0))

        let menu = try makeMenu(harness: harness, clickedCharacterIndex: 1)

        #expect(customItems(in: menu).allSatisfy { !$0.isEnabled })
    }

    @Test("Swift Stringへ変換できないUTF-16範囲なら追加commandを無効にする")
    func disablesCommandsForInvalidUTF16Selection() throws {
        let textView = ForcedSelectionTextView(usingTextLayoutManager: true)
        let harness = makeHarness(initialText: "本文", textView: textView)
        textView.forcedSelectionRange = NSRange(location: 99, length: 1)

        let menu = try makeMenu(harness: harness, clickedCharacterIndex: 99)

        #expect(customItems(in: menu).allSatisfy { !$0.isEnabled })
    }

    @Test("IME marked text中は追加commandを無効にする")
    func disablesCommandsDuringIMEComposition() throws {
        let harness = makeHarness(initialText: "本文")
        harness.textView.setSelectedRange(NSRange(location: 2, length: 0))
        harness.textView.setMarkedText(
            "か",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(harness.textView.hasMarkedText())

        let menu = try makeMenu(harness: harness, clickedCharacterIndex: 2)

        #expect(customItems(in: menu).allSatisfy { !$0.isEnabled })
    }

    @Test("menu表示後にselectionが変われば古いactionを実行しない")
    func rejectsActionAfterSelectionChanges() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let originalRange = NSRange(location: 0, length: 1)
        harness.textView.setSelectedRange(originalRange)
        let menu = try makeMenu(harness: harness, clickedCharacterIndex: 0)
        let firstCommand = try #require(customItems(in: menu).first)

        harness.textView.setSelectedRange(NSRange(location: 2, length: 1))
        let action = try #require(firstCommand.action)
        #expect(NSApplication.shared.sendAction(action, to: firstCommand.target, from: firstCommand))

        #expect(harness.captures.values.isEmpty)
        #expect(harness.textView.string == "猫と犬")
        #expect(!harness.coordinator.undoManager.canUndo)
        #expect(harness.captures.textChanges.isEmpty)
    }

    @Test("別Coordinatorへactive ownershipが移った後は旧surfaceのcommandを無効にする")
    func disablesCommandsAfterActiveOwnershipMoves() throws {
        let sharedSession = EditorCommandSession()
        let oldSurface = makeHarness(initialText: "旧本文", session: sharedSession)
        oldSurface.textView.setSelectedRange(NSRange(location: 0, length: 1))

        let newSurface = makeHarness(initialText: "世界観ノート", session: sharedSession)
        let menu = try makeMenu(harness: oldSurface, clickedCharacterIndex: 0)

        #expect(sharedSession.isActiveEditorSurface(newSurface.coordinator.commandSurfaceToken))
        #expect(customItems(in: menu).allSatisfy { !$0.isEnabled })
        #expect(oldSurface.captures.values.isEmpty)
        #expect(oldSurface.captures.textChanges.isEmpty)
    }

    @Test("menu表示後に別Coordinatorへownershipが移れば旧actionを実行しない")
    func rejectsActionAfterActiveOwnershipMoves() throws {
        let sharedSession = EditorCommandSession()
        let oldSurface = makeHarness(initialText: "旧本文", session: sharedSession)
        let originalRange = NSRange(location: 0, length: 1)
        oldSurface.textView.setSelectedRange(originalRange)
        let menu = try makeMenu(harness: oldSurface, clickedCharacterIndex: 0)
        let firstCommand = try #require(customItems(in: menu).first)

        let newSurface = makeHarness(initialText: "世界観ノート", session: sharedSession)
        let action = try #require(firstCommand.action)
        #expect(NSApplication.shared.sendAction(action, to: firstCommand.target, from: firstCommand))

        #expect(sharedSession.isActiveEditorSurface(newSurface.coordinator.commandSurfaceToken))
        #expect(oldSurface.captures.values.isEmpty)
        #expect(oldSurface.textView.string == "旧本文")
        #expect(oldSurface.textView.selectedRange() == originalRange)
        #expect(!oldSurface.coordinator.undoManager.canUndo)
        #expect(oldSurface.captures.textChanges.isEmpty)
    }

    @Test("command配列が空なら標準menuだけをそのまま返す")
    func emptyCommandArrayReturnsStandardMenu() throws {
        let harness = makeHarness(initialText: "本文", commandCount: 0)
        let standardMenu = NSMenu()
        standardMenu.addItem(NSMenuItem(title: "標準コピー", action: nil, keyEquivalent: ""))

        let returnedMenu = try #require(harness.coordinator.textView(
            harness.textView,
            menu: standardMenu,
            for: makeEvent(),
            at: 0
        ))

        #expect(returnedMenu === standardMenu)
        #expect(returnedMenu.items.map(\.title) == ["標準コピー"])
    }
}
#endif
