import Foundation

@MainActor
final class CaretEventObserver: NSObject {
    let handler: (Notification) -> Void

    init(handler: @escaping (Notification) -> Void) {
        self.handler = handler
    }

    @objc func receive(_ notification: Notification) {
        handler(notification)
    }
}
