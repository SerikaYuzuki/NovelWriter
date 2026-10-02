import AppKit
import SwiftUI

/// SwiftUI's doubleColumn visibility hides the project sidebar, not the outline.
/// Collapse only the native content item while keeping the split and sidebar alive.
struct WorkbenchContentColumnVisibility: NSViewRepresentable {
    let isCollapsed: Bool

    func makeNSView(context _: Context) -> ColumnObserver {
        ColumnObserver()
    }

    func updateNSView(_ view: ColumnObserver, context _: Context) {
        view.isContentCollapsed = isCollapsed
        view.scheduleUpdate()
    }

    final class ColumnObserver: NSView {
        var isContentCollapsed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in self?.applyVisibility() }
        }

        private func applyVisibility() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController,
                   controller.splitViewItems.count == 3 {
                    let content = controller.splitViewItems[1]
                    content.canCollapse = true
                    if content.isCollapsed != isContentCollapsed {
                        content.isCollapsed = isContentCollapsed
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
