import Foundation

public extension SyncV2Application {
    /// Coalesced invalidations, not account or manuscript data. Subscribers
    /// read the latest projection using their own current work/session scope.
    func stateChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stateChangeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateObserver(id) }
        }
        continuation.yield(())
        return stream
    }
}

private extension SyncV2Application {
    func removeStateObserver(_ id: UUID) {
        stateChangeContinuations[id] = nil
    }
}
