import Foundation
import NovelSyncV2

/// One policy for both Apple applications; tests advance the injected clock.
package struct SyncV2PromotionClock: Sendable {
    package static let idleInterval: TimeInterval = 60
    package static let maximumInterval: TimeInterval = 300
    package let now: @Sendable () -> Date
    package let sleep: @Sendable (TimeInterval) async throws -> Void
    package init(now: @escaping @Sendable () -> Date,
                 sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    /// Dates here are an opaque monotonic timeline, never a wall-clock timestamp.
    package static let live = SyncV2PromotionClock(now: {
        Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime)
    }, sleep: {
        try await Task.sleep(for: .seconds($0))
    })
}

public extension SyncV2Application {
    /// Manual/lifecycle save boundary after the platform's IME/revision flush.
    /// Already-clean editors still promote their last autosave; no network is awaited.
    func promoteCheckpoint(workID: WorkID) async throws {
        guard runtimeIdentity != .preview else { throw SyncV2ApplicationError.previewReadOnly }
        let promoted = try await kernel.promoteCurrentLeaf(workID: workID)
        cancelLeafPromotion(workID: workID)
        if promoted {
            scheduleWorker(for: workID)
        }
    }
}

extension SyncV2Application {
    func cancelLeafPromotion(workID: WorkID) {
        let previous = lanes[workID]?.promotion
        lanes[workID, default: WorkLane()].promotion = .idle
        previous?.task?.cancel()
        takeLaneValue(\.promotionDeadline, workID: workID)
    }

    func scheduleLeafPromotion(workID: WorkID) {
        lanes[workID, default: WorkLane()].promotionTask?.cancel()
        let now = promotionClock.now()
        let maximum = lanes[workID, default: WorkLane()].promotionDeadline ?? now.addingTimeInterval(SyncV2PromotionClock.maximumInterval)
        lanes[workID, default: WorkLane()].promotionDeadline = maximum
        let deadline = min(now.addingTimeInterval(SyncV2PromotionClock.idleInterval), maximum)
        let clock = promotionClock
        let owner = UUID()
        let task = Task<Void, Never> { [weak self] in
            do {
                try await clock.sleep(max(0, deadline.timeIntervalSince(clock.now())))
                try Task.checkCancellation()
                try await self?.promoteTimedLeaf(workID: workID, owner: owner)
            } catch {
                // Local bytes remain durable. Open/lifecycle/explicit sync
                // recover a promotion interrupted by cancellation or failure.
            }
        }
        lanes[workID, default: WorkLane()].promotion = .running(owner: owner, task: task)
    }

    private func promoteTimedLeaf(workID: WorkID, owner: UUID) async throws {
        guard lanes[workID, default: WorkLane()].promotionOwner == owner, remoteSchedulingSuspensions.isEmpty,
              !lanes[workID, default: WorkLane()].deletionPending else { return }
        let promoted = try await kernel.promoteCurrentLeaf(workID: workID)
        if lanes[workID, default: WorkLane()].promotionOwner == owner {
            cancelLeafPromotion(workID: workID)
        }
        if promoted {
            scheduleWorker(for: workID)
        }
    }
}
