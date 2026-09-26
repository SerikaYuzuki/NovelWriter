#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

@MainActor
struct MacCaretConfigurationTests {
    @Test("カーソル設定だけの変更は本文属性・選択・Undoを再構築しない")
    func toggleDoesNotReapplyTextAttributes() {
        let (editor, coordinator) = makeEditor()
        let undo = coordinator.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertText("追記", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        let selection = editor.selectedRange()
        for enabled in [true, false, true] {
            coordinator.applyConfigurationIfNeeded(EditorConfiguration(animatesCaret: enabled), to: editor)
            #expect(editor.motionEnabled == enabled)
            #expect(coordinator.lastAppliedConfiguration?.animatesCaret == enabled)
            #expect(coordinator.textStorageAttributeApplicationCount == 1)
            #expect(editor.string == "本文追記")
            #expect(editor.selectedRange() == selection)
            #expect(editor.textLayoutManager != nil)
        }
        #expect(undo.canUndo)
        undo.undo()
        #expect(editor.string == "本文")
        undo.redo()
        #expect(editor.string == "本文追記")
    }

    @Test("IME中もカーソル設定だけは切り替え、フォント変更は確定後まで保留する")
    func toggleWhileComposing() {
        let (editor, coordinator) = makeEditor()
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let selection = editor.selectedRange()
        let configuration = EditorConfiguration(fontSize: 18, animatesCaret: true)
        coordinator.applyConfigurationIfNeeded(configuration, to: editor)
        #expect(editor.motionEnabled)
        #expect(editor.markedRange() == marked)
        #expect(editor.selectedRange() == selection)
        #expect(editor.string == "本文かな")
        #expect(coordinator.textStorageAttributeApplicationCount == 1)
        #expect(coordinator.lastAppliedConfiguration?.fontSize == 16)
        editor.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.applyConfigurationIfNeeded(configuration, to: editor)
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "本文仮名")
        #expect(coordinator.textStorageAttributeApplicationCount == 2)
        #expect(coordinator.lastAppliedConfiguration == configuration)
    }

    private func makeEditor() -> (AnimatedCaretTextView, MacTextAdapter.Coordinator) {
        let editor = AnimatedCaretTextView(usingTextLayoutManager: true)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.string = "本文"
        let coordinator = MacTextAdapter.Coordinator(onTextChange: { _ in })
        coordinator.textView = editor
        editor.delegate = coordinator
        coordinator.applyConfigurationIfNeeded(EditorConfiguration(), to: editor)
        coordinator.undoManager.removeAllActions()
        return (editor, coordinator)
    }
}
#endif
