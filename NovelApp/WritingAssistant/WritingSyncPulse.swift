import SwiftUI

/// Lives with the open work, independently of the chat panel and manuscript saves.
struct WritingSyncPulse: ViewModifier {
    let host: WritingAssistantHost?
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content.task(id: host?.contextID) {
            guard let host else { return }
            while !Task.isCancelled {
                if scenePhase == .active {
                    try? await host.synchronize()
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
}
