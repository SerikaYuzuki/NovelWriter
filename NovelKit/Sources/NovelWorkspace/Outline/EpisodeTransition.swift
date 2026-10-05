import NovelCore

/// OS navigation hooks retain editor preparation/resume and their document gate.
@MainActor
public protocol WorkspaceEpisodeTransitionHost: WorkspaceOutlineHost {
    func episodeTransitionBoundary(context: WorkspaceOperationContext, operation: @MainActor () async -> Bool) async -> Bool
    var permitsEpisodeTransitionCompletion: Bool { get }
    func prepareEpisodeDeparture() async -> Bool
    func saveAfterEpisodeTransition() async -> Bool
}

@MainActor
public struct EpisodeTransition {
    private let host: any WorkspaceEpisodeTransitionHost

    public init(host: any WorkspaceEpisodeTransitionHost) {
        self.host = host
    }

    public func perform(saveAfter: Bool = false, expectedSession: WorkspaceSessionToken? = nil,
                        operation: @MainActor () -> Bool) async -> Bool {
        let context = host.operationContext
        guard host.permitsLocalMutation, context.session != nil,
              expectedSession == nil || context.session == expectedSession else { return false }
        return await host.episodeTransitionBoundary(context: context) {
            guard isCurrent(context), await host.prepareEpisodeDeparture(),
                  isCurrent(context), host.permitsEpisodeTransitionCompletion, !Task.isCancelled, operation() else { return false }
            if saveAfter {
                guard await host.saveAfterEpisodeTransition(), isCurrent(context) else { return false }
            }
            return true
        }
    }

    private func isCurrent(_ context: WorkspaceOperationContext) -> Bool {
        let current = host.operationContext
        return current.workID == context.workID && current.session == context.session && current.account == context.account
    }
}
