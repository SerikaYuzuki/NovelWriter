import Foundation
import NovelSyncV2

public enum SyncV2WakeReason: Sendable {
    case launch
    case foreground
    case systemWake
    case networkRecovery
}

struct SyncV2WakeFlight {
    let owner: UUID
    let scope: UInt64
    let task: Task<Void, Error>
}

struct SyncV2ForegroundObservation {
    let owner: UUID
    let task: Task<Void, Never>
    let finished: CheckedContinuation<Void, Never>
}

public extension SyncV2Application {
    /// Coalesce overlapping lifecycle hints into one durable scan. This only
    /// schedules remote lanes; it never awaits their network work.
    func wake(reason _: SyncV2WakeReason) async throws {
        let flight = beginLifecycleWake()
        defer {
            if lifecycleWake?.owner == flight.owner {
                lifecycleWake = nil
            }
        }
        try await flight.task.value
    }

    internal func beginLifecycleWake() -> SyncV2WakeFlight {
        if let flight = lifecycleWake, flight.scope == historyScopeGeneration {
            return flight
        }
        let flight = SyncV2WakeFlight(owner: UUID(), scope: historyScopeGeneration,
                                      task: Task { try await self.resumePending() })
        lifecycleWake = flight
        return flight
    }

    /// The platform reports the lifetime of its foreground work. The application
    /// owns the polling task; cancellation withdraws only this observation.
    func observeForegroundSynchronization(
        workID: WorkID,
        refresh: @escaping @Sendable () async -> Void
    ) async {
        let owner = UUID()
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { continuation in
                if let previous = foregroundObservations.removeValue(forKey: workID) {
                    previous.task.cancel()
                    previous.finished.resume()
                }
                let task = Task { [weak self] in
                    await self?.pollForeground(workID: workID, refresh: refresh)
                    await self?.endForegroundObservation(workID: workID, owner: owner)
                }
                foregroundObservations[workID] = SyncV2ForegroundObservation(
                    owner: owner, task: task, finished: continuation
                )
            }
        } onCancel: {
            Task { await self.endForegroundObservation(workID: workID, owner: owner) }
        }
    }

    private func endForegroundObservation(workID: WorkID, owner: UUID) {
        guard let observation = foregroundObservations[workID], observation.owner == owner else { return }
        foregroundObservations[workID] = nil
        observation.task.cancel()
        observation.finished.resume()
    }
}
