import AppKit
import SwiftUI

/// A native search field inside a regular customizable item, with no positional lock.
struct WorkbenchSearchField: NSViewRepresentable {
    @Binding var query: String
    let focusRequest: UUID?
    let search: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "話内を検索"
        field.setAccessibilityLabel("話内を検索")
        field.identifier = NSUserInterfaceItemIdentifier("workbench.search.field")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.sendsWholeSearchString = true
        field.stringValue = query
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.owner = self
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if field.stringValue != query, !composing {
            field.stringValue = query
        }
        if let focusRequest, context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var owner: WorkbenchSearchField
        var lastFocusRequest: UUID?
        init(_ owner: WorkbenchSearchField) {
            self.owner = owner
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            owner.query = field.stringValue
        }

        @objc func submit(_ field: NSSearchField) {
            owner.query = field.stringValue
            owner.search()
        }
    }
}
