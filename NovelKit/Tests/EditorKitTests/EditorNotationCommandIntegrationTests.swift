#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

@MainActor
struct EditorNotationCommandIntegrationTests {
    private func makeHarness(initialText: String) -> (NSTextView, MacTextAdapter.Coordinator) {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 16)]
        textView.string = initialText

        let coordinator = MacTextAdapter.Coordinator(onTextChange: { _ in })
        coordinator.textView = textView
        textView.delegate = coordinator
        return (textView, coordinator)
    }

    @Test("絵文字後のUTF-16選択をルビ記法へ置換してUndoできる")
    func replacesUnicodeSelectionWithRubyAndUndo() throws {
        let (textView, coordinator) = makeHarness(initialText: "😀猫")
        let session = EditorCommandSession()
        let selectedRange = NSRange(location: 2, length: 1)
        textView.setSelectedRange(selectedRange)
        let notation = try #require(EditorNotationRules.ruby(parentText: "猫", rubyText: "ねこ"))

        let id = session.requestSelectionSnapshot()
        coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)
        #expect(session.selectionSnapshot?.range == selectedRange)
        session.replaceSelection(id: id, text: notation)
        coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)

        #expect(textView.string == "😀｜猫《ねこ》")
        coordinator.undoManager.undo()
        #expect(textView.string == "😀猫")
    }

    @Test("傍点記法の選択置換もUndo一回で戻せる")
    func replacesSelectionWithBoutenAndUndo() throws {
        let original = "例えばこの文章"
        let (textView, coordinator) = makeHarness(initialText: original)
        let session = EditorCommandSession()
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
        let notation = try #require(EditorNotationRules.bouten(text: original))

        let id = session.requestSelectionSnapshot()
        coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)
        session.replaceSelection(id: id, text: notation)
        coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)

        #expect(textView.string == "｜例《・》｜え《・》｜ば《・》｜こ《・》｜の《・》｜文《・》｜章《・》")
        coordinator.undoManager.undo()
        #expect(textView.string == original)
    }

    @Test("snapshot後に選択が変わった場合の置換を拒否する")
    func rejectsStaleSelectionSnapshot() throws {
        let (textView, coordinator) = makeHarness(initialText: "猫と犬")
        let session = EditorCommandSession()
        textView.setSelectedRange(NSRange(location: 0, length: 1))

        let id = session.requestSelectionSnapshot()
        coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)
        _ = try #require(session.selectionSnapshot)
        textView.setSelectedRange(NSRange(location: 2, length: 1))
        session.replaceSelection(id: id, text: "｜猫《・》")
        coordinator.applyEditorCommandIfNeeded(session.pendingCommand, session: session, textView: textView)

        #expect(session.rejectedCommandID == id)
        #expect(textView.string == "猫と犬")
    }
}
#endif
