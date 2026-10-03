import NovelWritingSupport
import SwiftUI

/// Lives with the open work, independently of manuscript saves.
struct WritingSyncPulse: ViewModifier {
    let host: WritingAssistantHost?
    @State private var attachedHost: WritingAssistantHost?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { attach() }
            .onChange(of: host?.contextID) { _, _ in attach() }
            .onChange(of: scenePhase) { _, phase in
                guard let host else { return }
                host.syncScheduler?.setForeground(phase == .active, contextID: host.contextID)
            }
            .onDisappear {
                if let attachedHost {
                    attachedHost.syncScheduler?.detach(contextID: attachedHost.contextID)
                }
                attachedHost = nil
            }
    }

    private func attach() {
        if let attachedHost {
            attachedHost.syncScheduler?.detach(contextID: attachedHost.contextID)
        }
        attachedHost = host
        guard let host else { return }
        host.syncScheduler?.attach(contextID: host.contextID, foreground: scenePhase == .active,
                                   synchronize: host.synchronize)
    }
}

/// Count visible surfaces, including sheets, without making a second polling lane.
struct WritingSyncVisibility: ViewModifier {
    let host: WritingAssistantHost?
    @State private var token = UUID()
    @State private var visibleHost: WritingAssistantHost?

    func body(content: Content) -> some View {
        content
            .onAppear { register() }
            .onChange(of: host?.contextID) { _, _ in register() }
            .onDisappear { unregister() }
    }

    private func register() {
        unregister()
        visibleHost = host
        guard let host else { return }
        host.syncScheduler?.setVisible(true, token: token, contextID: host.contextID)
    }

    private func unregister() {
        if let visibleHost {
            visibleHost.syncScheduler?.setVisible(false, token: token, contextID: visibleHost.contextID)
        }
        visibleHost = nil
    }
}
