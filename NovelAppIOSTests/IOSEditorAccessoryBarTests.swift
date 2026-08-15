import EditorKit
import Foundation
@testable import FUMINIWAIOS
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS editor accessory bar", .serialized)
struct IOSEditorAccessoryBarTests {
    final class Changes {
        var values: [String] = []
    }

    struct Harness {
        let commandSession: EditorCommandSession
        let commandState: IOSEditorAccessoryCommandState
        let changes: Changes
        let textView: UITextView
        let undoManager: UndoManager
        let window: UIWindow

        func cleanup() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    @Test("外付けキーボードの4操作は衝突しない固定shortcutを持つ")
    func hardwareKeyboardShortcutsAreDistinct() {
        let shortcuts = [
            IOSEditorAccessoryOperation.ellipsis.keyboardShortcut.character,
            IOSEditorAccessoryOperation.dash.keyboardShortcut.character,
            IOSEditorAccessoryOperation.ruby.keyboardShortcut.character,
            IOSEditorAccessoryOperation.bouten.keyboardShortcut.character
        ]

        #expect(shortcuts == ["1", "2", "3", "4"])
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test("三点リーダーとダッシュはpending中の重複操作を拒否しUndo一回で戻る")
    func punctuationCommandsUseOneUndoStep() async throws {
        let harness = try await makeHarness(initialText: "本文")
        defer { harness.cleanup() }
        let insertionRange = NSRange(location: (harness.textView.text as NSString).length, length: 0)
        updateSelection(insertionRange, in: harness.textView)

        harness.commandState.request(.ellipsis, commandSession: harness.commandSession)
        let firstOperation = harness.commandState.pendingOperation
        harness.commandState.request(.dash, commandSession: harness.commandSession)

        #expect(harness.commandState.pendingOperation == firstOperation)
        await advanceMainRunLoop(until: { harness.textView.text == "本文……" })
        #expect(harness.textView.text == "本文……")
        #expect(harness.undoManager.canUndo)

        for _ in 0 ..< 2 {
            harness.undoManager.undo()
            #expect(harness.textView.text == "本文")
            #expect(harness.undoManager.canRedo)
            harness.undoManager.redo()
            #expect(harness.textView.text == "本文……")
        }
        harness.undoManager.undo()

        updateSelection(insertionRange, in: harness.textView)
        harness.commandState.request(.dash, commandSession: harness.commandSession)
        await advanceMainRunLoop(until: { harness.textView.text == "本文――" })
        #expect(harness.textView.text == "本文――")
        #expect(harness.undoManager.canUndo)

        for _ in 0 ..< 2 {
            harness.undoManager.undo()
            #expect(harness.textView.text == "本文")
            #expect(harness.undoManager.canRedo)
            harness.undoManager.redo()
            #expect(harness.textView.text == "本文――")
        }
    }

    @Test("ルビはselection snapshotへ拘束して置換しUndo一回で戻る")
    func rubyUsesSelectionSnapshotAndOneUndoStep() async throws {
        let harness = try await makeHarness(initialText: "前😀猫後")
        defer { harness.cleanup() }
        let selectedRange = (harness.textView.text as NSString).range(of: "猫")
        updateSelection(selectedRange, in: harness.textView)

        harness.commandState.request(.ruby, commandSession: harness.commandSession)
        await advanceMainRunLoop(until: { harness.commandState.rubySheet != nil })
        let sheet = try #require(harness.commandState.rubySheet)
        #expect(sheet.snapshot.text == "猫")
        #expect(sheet.snapshot.range == selectedRange)

        harness.commandState.completeRuby(
            parentText: "猫",
            rubyText: "ねこ",
            commandSession: harness.commandSession
        )
        await advanceMainRunLoop(until: { harness.textView.text == "前😀｜猫《ねこ》後" })

        #expect(harness.textView.text == "前😀｜猫《ねこ》後")
        #expect(harness.undoManager.canUndo)
        for _ in 0 ..< 2 {
            harness.undoManager.undo()
            #expect(harness.textView.text == "前😀猫後")
            #expect(harness.undoManager.canRedo)
            harness.undoManager.redo()
            #expect(harness.textView.text == "前😀｜猫《ねこ》後")
        }
    }

    @Test("傍点は選択必須で、選択置換をUndo一回で戻す")
    func boutenRequiresSelectionAndUsesOneUndoStep() async throws {
        let original = "猫😀と犬"
        let harness = try await makeHarness(initialText: original)
        defer { harness.cleanup() }
        let selectedRange = (harness.textView.text as NSString).range(of: "猫😀")
        updateSelection(selectedRange, in: harness.textView)

        harness.commandState.request(.bouten, commandSession: harness.commandSession)
        let expected = "｜猫《・》｜😀《・》と犬"
        await advanceMainRunLoop(until: { harness.textView.text == expected })

        #expect(harness.textView.text == expected)
        #expect(harness.undoManager.canUndo)
        for _ in 0 ..< 2 {
            harness.undoManager.undo()
            #expect(harness.textView.text == original)
            #expect(harness.undoManager.canRedo)
            harness.undoManager.redo()
            #expect(harness.textView.text == expected)
        }
        harness.undoManager.undo()

        updateSelection(NSRange(location: 0, length: 0), in: harness.textView)
        harness.commandState.request(.bouten, commandSession: harness.commandSession)
        await advanceMainRunLoop(until: { harness.commandState.replacementError != nil })

        #expect(harness.textView.text == original)
        #expect(harness.commandState.replacementError == "傍点を付ける文字を選択してください。")
    }

    @Test("IME変換中の挿入commandは本文を変更せず拒否する")
    func commandIsRejectedDuringComposition() async throws {
        let harness = try await makeHarness(initialText: "本文")
        defer { harness.cleanup() }
        updateSelection(
            NSRange(location: (harness.textView.text as NSString).length, length: 0),
            in: harness.textView
        )
        harness.textView.setMarkedText(
            "変換中",
            selectedRange: NSRange(location: ("変換中" as NSString).length, length: 0)
        )
        let composingText = harness.textView.text
        #expect(harness.textView.markedTextRange != nil)

        harness.commandState.request(.ellipsis, commandSession: harness.commandSession)
        await advanceMainRunLoop(until: { harness.commandState.replacementError != nil })

        #expect(harness.textView.text == composingText)
        #expect(!harness.textView.text.contains("……"))
        #expect(harness.commandState.pendingOperation == nil)
        #expect(harness.commandSession.pendingCommand == nil)
    }

    @Test("ルビsheet中に選択が変わるとstale置換を拒否する")
    func rubyRejectsStaleSelection() async throws {
        let original = "猫と犬"
        let harness = try await makeHarness(initialText: original)
        defer { harness.cleanup() }
        updateSelection((original as NSString).range(of: "猫"), in: harness.textView)

        harness.commandState.request(.ruby, commandSession: harness.commandSession)
        await advanceMainRunLoop(until: { harness.commandState.rubySheet != nil })
        _ = try #require(harness.commandState.rubySheet)

        updateSelection((original as NSString).range(of: "犬"), in: harness.textView)
        harness.commandState.completeRuby(
            parentText: "猫",
            rubyText: "ねこ",
            commandSession: harness.commandSession
        )
        await advanceMainRunLoop(until: { harness.commandState.replacementError != nil })

        #expect(harness.textView.text == original)
        #expect(harness.commandState.rubySheet == nil)
        #expect(harness.commandSession.pendingCommand == nil)
    }

    private func makeHarness(initialText: String) async throws -> Harness {
        let commandSession = EditorCommandSession()
        let commandState = IOSEditorAccessoryCommandState()
        let changes = Changes()
        let rootView = EditorView(
            chapterKey: "episode",
            initialText: initialText,
            commandSession: commandSession,
            onTextChange: { changes.values.append($0) }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IOSEditorAccessoryBar(
                commandSession: commandSession,
                commandState: commandState
            )
        }
        let host = UIHostingController(rootView: rootView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()

        await advanceMainRunLoop(until: {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            return findTextView(in: host.view) != nil
        })
        let textView = try #require(findTextView(in: host.view))
        _ = textView.becomeFirstResponder()
        let undoManager = try #require(textView.undoManager)
        undoManager.removeAllActions()

        return Harness(
            commandSession: commandSession,
            commandState: commandState,
            changes: changes,
            textView: textView,
            undoManager: undoManager,
            window: window
        )
    }

    private func updateSelection(_ range: NSRange, in textView: UITextView) {
        textView.selectedRange = range
        textView.delegate?.textViewDidChangeSelection?(textView)
    }

    private func advanceMainRunLoop(
        until condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 120 {
            if condition() {
                return
            }
            await withCheckedContinuation { continuation in
                RunLoop.main.perform {
                    continuation.resume()
                }
            }
        }
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }
}
