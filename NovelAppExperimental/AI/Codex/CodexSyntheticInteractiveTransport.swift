import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex synthetic interactive transport must only compile in FUMINIWAExperimental")
#endif

actor CodexSyntheticInteractiveTransport {
    private let factory: any CodexSyntheticInteractiveChannelFactory
    private let channelReuseRegistry = CodexSyntheticChannelReuseRegistry.shared
    private var currentSession: CodexSyntheticInteractiveSession?

    init(factory: any CodexSyntheticInteractiveChannelFactory) {
        self.factory = factory
    }

    func run(
        _ request: CodexSyntheticInteractiveTransportRequest
    ) async throws -> CodexSyntheticInteractiveTerminal {
        guard currentSession == nil else {
            throw CodexSyntheticInteractiveTransportError.alreadyRunning
        }
        guard request.expectedRuntime.identity.mode == .mock else {
            throw CodexSyntheticInteractiveTransportError.nonMockRuntimeExpectation
        }

        let session = CodexSyntheticInteractiveSession(
            factory: factory,
            request: request,
            channelReuseRegistry: channelReuseRegistry
        )
        currentSession = session
        defer {
            if currentSession === session {
                currentSession = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            Task {
                await session.requestStop(.cancelled)
            }
        }
    }

    func cancel() async {
        await currentSession?.requestStop(.cancelled)
    }
}
