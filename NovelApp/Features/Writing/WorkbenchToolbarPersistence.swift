import AppKit
import SwiftUI

/// SwiftUI can rebuild the native toolbar when its hosting view is recreated.
/// Keep the user's native customization separately and restore after that rebuild.
struct WorkbenchToolbarPersistence: NSViewRepresentable {
    let profile: String
    var defaults: UserDefaults = .standard

    func makeNSView(context _: Context) -> ObserverView {
        ObserverView(profile: profile, defaults: defaults)
    }

    func updateNSView(_: ObserverView, context _: Context) {}

    final class ObserverView: NSView {
        private let profile: String
        private let defaults: UserDefaults
        private weak var observedToolbar: NSToolbar?
        private var restoration: Task<Void, Never>?
        private var pendingSave: Task<Void, Never>?
        private var ready = false

        init(profile: String, defaults: UserDefaults) {
            self.profile = profile
            self.defaults = defaults
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restoration?.cancel()
            pendingSave?.cancel()
            ready = false
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { return }
            restoration = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let toolbar = window?.toolbar else { return }
                observedToolbar = toolbar
                restore(toolbar)
                ready = true
                for name in [NSToolbar.didRemoveItemNotification, NSToolbar.willAddItemNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(itemsChanged(_:)), name: name, object: toolbar)
                }
                NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)),
                                                       name: NSWindow.willCloseNotification, object: window)
            }
        }

        private func restore(_ toolbar: NSToolbar) {
            if let saved = defaults.stringArray(forKey: storageKey(toolbar)) {
                let allowed = Set(toolbar.delegate?.toolbarAllowedItemIdentifiers?(toolbar) ?? [])
                let order = saved.map { NSToolbarItem.Identifier($0) }.filter { allowed.contains($0) }
                // Tracking separators belong to the split view, not the customization palette.
                // Keep their existing positions while restoring the movable items around them.
                let tracking = toolbar.items.enumerated().filter { $0.element is NSTrackingSeparatorToolbarItem }
                var restored = order.filter { id in !tracking.contains { $0.element.itemIdentifier == id } }
                for (index, item) in tracking {
                    restored.insert(item.itemIdentifier, at: min(index, restored.count))
                }
                if #available(macOS 15, *) {
                    toolbar.itemIdentifiers = restored
                } else {
                    for index in toolbar.items.indices.reversed() {
                        toolbar.removeItem(at: index)
                    }
                    for (index, id) in restored.enumerated() {
                        toolbar.insertItem(withItemIdentifier: id, at: index)
                    }
                }
            }
        }

        private func storageKey(_ toolbar: NSToolbar) -> String {
            "fuminiwa.toolbar.order.\(toolbar.identifier).\(profile)"
        }

        @objc private func windowClosing(_: Notification) {
            // Closing immediately after a drag must not lose the debounced change.
            guard ready, pendingSave != nil, let toolbar = observedToolbar, !toolbar.items.isEmpty else { return }
            defaults.set(toolbar.items.map(\.itemIdentifier.rawValue), forKey: storageKey(toolbar))
            pendingSave?.cancel()
            ready = false
        }

        @objc private func itemsChanged(_: Notification) {
            guard ready else { return }
            pendingSave?.cancel()
            pendingSave = Task { @MainActor [weak self] in
                // A move emits remove and add; capture only the completed operation.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, ready,
                      let toolbar = observedToolbar, window?.isVisible == true,
                      !toolbar.items.isEmpty else { return }
                defaults.set(toolbar.items.map(\.itemIdentifier.rawValue), forKey: storageKey(toolbar))
            }
        }
    }
}
