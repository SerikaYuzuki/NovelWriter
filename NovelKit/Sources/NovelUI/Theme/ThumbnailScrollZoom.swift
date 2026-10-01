#if os(macOS)
import AppKit
import SwiftUI

/// A passive local monitor leaves drag/pinch hit testing with SwiftUI.
struct ThumbnailScrollZoom: NSViewRepresentable {
    let onScroll: (Double) -> Void
    func makeNSView(context _: Context) -> ScrollRegion {
        let view = ScrollRegion()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ScrollRegion, context _: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: ScrollRegion, coordinator _: ()) {
        view.stopMonitoring()
    }

    final class ScrollRegion: NSView {
        var onScroll: ((Double) -> Void)?
        private var monitor: Any?
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                    self.onScroll?(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
                    return true
                }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
#endif
