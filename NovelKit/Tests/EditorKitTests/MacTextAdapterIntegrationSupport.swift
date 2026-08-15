#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

extension MacTextAdapterIntegrationTests {
    struct Harness {
        let textView: NSTextView
        let coordinator: MacTextAdapter.Coordinator
        let changes: Changes
    }

    final class Changes {
        var received: [String] = []
    }

    func makeHarness(initialText: String) -> Harness {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 16)]
        textView.string = initialText

        let changes = Changes()
        let coordinator = MacTextAdapter.Coordinator(onTextChange: { changes.received.append($0) })
        coordinator.textView = textView
        textView.delegate = coordinator

        return Harness(textView: textView, coordinator: coordinator, changes: changes)
    }

    func beginIMEComposition(in textView: NSTextView) {
        textView.setMarkedText(
            "か",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }
}
#endif
