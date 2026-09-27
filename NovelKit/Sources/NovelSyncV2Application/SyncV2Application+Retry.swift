import Foundation
import NovelSyncV2

extension SyncV2Application {
    static func retryDelay(attempt: Int, jitter: Double) -> TimeInterval {
        min(60, pow(2, Double(min(max(attempt, 0) + 1, 6))) * min(1.25, max(0.75, jitter)))
    }

    func cancelRetry(for workID: WorkID) {
        retryTasks.removeValue(forKey: workID)?.cancel()
        retryOwners[workID] = nil
    }

    func scheduleRetryIfNeeded(for workID: WorkID) {
        guard runtimeIdentity != .preview, remoteSchedulingSuspensions.isEmpty,
              !deletingWorkIDs.contains(workID), retryTasks[workID] == nil else { return }
        switch states[workID]?.remoteProgress {
        case .offline, .retryable(.serverUnavailable), .retryable(.lostResponse): break
        default: return
        }
        let owner = UUID()
        let delay = Self.retryDelay(attempt: retryAttempts[workID, default: 0], jitter: Double.random(in: 0.75 ... 1.25))
        retryAttempts[workID, default: 0] += 1
        retryOwners[workID] = owner
        retryTasks[workID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.wakeRetry(workID: workID, owner: owner)
        }
    }

    private func wakeRetry(workID: WorkID, owner: UUID) {
        guard retryOwners[workID] == owner, !Task.isCancelled else { return }
        cancelRetry(for: workID)
        scheduleWorker(for: workID)
    }
}
