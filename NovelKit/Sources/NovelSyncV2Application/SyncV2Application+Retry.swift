import Foundation
import NovelSyncV2

extension SyncV2Application {
    static func retryDelay(attempt: Int, jitter: Double) -> TimeInterval {
        min(60, pow(2, Double(min(max(attempt, 0) + 1, 6))) * min(1.25, max(0.75, jitter)))
    }

    func cancelRetry(for workID: WorkID) {
        let previous = lanes[workID]?.retry
        lanes[workID, default: WorkLane()].retry = .idle
        previous?.task?.cancel()
    }

    func scheduleRetryIfNeeded(for workID: WorkID) {
        guard runtimeIdentity != .preview, remoteSchedulingSuspensions.isEmpty,
              !lanes[workID, default: WorkLane()].deletionPending, lanes[workID, default: WorkLane()].retryTask == nil else { return }
        switch lanes[workID, default: WorkLane()].state?.remoteProgress {
        case .offline, .retryable(.serverUnavailable), .retryable(.lostResponse): break
        default: return
        }
        let owner = UUID()
        let delay = Self.retryDelay(attempt: lanes[workID, default: WorkLane()].retryAttempt, jitter: Double.random(in: 0.75 ... 1.25))
        lanes[workID, default: WorkLane()].retryAttempt += 1
        let task = Task<Void, Never> { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.wakeRetry(workID: workID, owner: owner)
        }
        lanes[workID, default: WorkLane()].retry = .running(owner: owner, task: task)
    }

    private func wakeRetry(workID: WorkID, owner: UUID) {
        guard lanes[workID, default: WorkLane()].retryOwner == owner, !Task.isCancelled else { return }
        cancelRetry(for: workID)
        scheduleWorker(for: workID)
    }
}
