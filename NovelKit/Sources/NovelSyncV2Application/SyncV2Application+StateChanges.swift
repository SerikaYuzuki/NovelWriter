import Foundation
import NovelSyncV2

public enum SyncV2ApplicationEvent: Sendable {
    case stateChanged(WorkID, SyncUIState)
    case adoptionAvailable(WorkID)
    case invalidated(WorkID?)

    public func concerns(_ workID: WorkID) -> Bool {
        switch self {
        case let .stateChanged(id, _), let .adoptionAvailable(id): id == workID
        case let .invalidated(id): id == nil || id == workID
        }
    }
}

struct SyncV2StateObserver {
    let workID: WorkID?
    let continuation: AsyncStream<SyncV2ApplicationEvent>.Continuation
}

public extension SyncV2Application {
    /// Register before reading durable state. No gap exists between the initial
    /// invalidation and later worker notifications. Deadlines terminate waits;
    /// cancellation removes the observer and cancels its deadline task.
    /// Coalescing keeps the latest state/adoption pair, not a command backlog.
    /// Work-specific subscribers cannot lose their wake to another work.
    func stateChanges(for workID: WorkID? = nil, until deadline: ContinuousClock.Instant? = nil) -> AsyncStream<SyncV2ApplicationEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncV2ApplicationEvent>.makeStream(bufferingPolicy: .bufferingNewest(2))
        stateChangeContinuations[id] = SyncV2StateObserver(workID: workID, continuation: continuation)
        let timeout = deadline.map { deadline in
            Task {
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                continuation.finish()
            }
        }
        continuation.onTermination = { [weak self] _ in
            timeout?.cancel()
            Task { await self?.removeStateObserver(id) }
        }
        continuation.yield(.invalidated(nil))
        return stream
    }
}

extension SyncV2Application {
    func updateLaneState(_ state: WorkLane.State?, workID: WorkID) {
        let previous = lanes[workID]?.state
        lanes[workID, default: WorkLane()].state = state
        guard previous != state else { return }
        guard let state else {
            emit(.invalidated(workID))
            return
        }
        emit(.stateChanged(workID, state.projection))
        if case .readyForSafeAdoption = state.remoteProgress {
            emit(.adoptionAvailable(workID))
        }
    }

    func emit(_ event: SyncV2ApplicationEvent) {
        for observer in stateChangeContinuations.values {
            guard observer.workID.map({ event.concerns($0) }) ?? true else { continue }
            observer.continuation.yield(event)
        }
    }

    private func removeStateObserver(_ id: UUID) {
        stateChangeContinuations[id] = nil
    }
}
