import Foundation
import NovelSyncV2

/// All process-local ownership for one work. Task owners survive cancellation
/// until their guarded completion, so an old completion cannot clear a new task.
struct WorkLane {
    var promotionDeadline: Date?
    var foregroundObservation: SyncV2ForegroundObservation?
    var syncDiagnostic: String?
    var writingCopyRetry: WorkID?
    var remoteOnlyOpen: Task<SyncV2OpenedWork, Error>?
    var importProgress: ImportProgress?
    var importFailure: SyncV2Failure?
    var deletionTask: Task<Void, Error>?
    var retryAttempt: Int = 0
    var wakeEpoch: UInt64 = 0
    var session: DocumentSessionToken?
    var automaticCheckInProgress = false
    var cleanRemoteCheck: TaskState = .idle
    var allowsConstrainedBackfill = false
    var manuallyRequestedBackfill = false
    var historyWaiting = false
    var shouldOpenImportedWork = false
    var deletionPending = false
    var worker: TaskState = .idle
    var workerOwner: UUID? {
        worker.owner
    }

    var workerTask: Task<Void, Never>? {
        worker.task
    }

    var retry: TaskState = .idle
    var retryOwner: UUID? {
        retry.owner
    }

    var retryTask: Task<Void, Never>? {
        retry.task
    }

    var promotion: TaskState = .idle
    var promotionOwner: UUID? {
        promotion.owner
    }

    var promotionTask: Task<Void, Never>? {
        promotion.task
    }

    var state: State?
    var lastFailure: SyncV2Failure? {
        state?.lastFailure
    }

    enum TaskState {
        case idle
        case running(owner: UUID, task: Task<Void, Never>)

        var owner: UUID? {
            guard case let .running(owner, _) = self else { return nil }
            return owner
        }

        var task: Task<Void, Never>? {
            guard case let .running(_, task) = self else { return nil }
            return task
        }
    }

    /// Scheduling facts. SyncUIState is created only at the presentation boundary.
    struct State: Equatable, Sendable {
        let workID: WorkID
        let localDurability: SyncV2LocalDurability
        let remoteProgress: SyncV2RemoteProgress
        var conflict: SyncV2ConflictProjection?
        let lastTypedResult: SyncV2TypedResult
        var lastFailure: SyncV2Failure?

        var projection: SyncUIState {
            SyncUIState(workID: workID, localDurability: localDurability,
                        remoteProgress: remoteProgress, conflict: conflict,
                        lastTypedResult: lastTypedResult, lastFailure: lastFailure)
        }
    }
}

extension SyncV2Application {
    func laneValues<Value>(_ key: KeyPath<WorkLane, Value?>) -> [WorkID: Value] {
        lanes.compactMapValues { $0[keyPath: key] }
    }

    @discardableResult
    func takeLaneValue<Value>(_ key: WritableKeyPath<WorkLane, Value?>, workID: WorkID) -> Value? {
        let value = lanes[workID]?[keyPath: key]
        lanes[workID, default: WorkLane()][keyPath: key] = nil
        return value
    }

    func clearLaneValues(_ key: WritableKeyPath<WorkLane, (some Any)?>) {
        for workID in lanes.keys {
            lanes[workID]?[keyPath: key] = nil
        }
    }

    @discardableResult
    func setLaneFlag(_ key: WritableKeyPath<WorkLane, Bool>, workID: WorkID, value: Bool) -> Bool {
        let previous = lanes[workID, default: WorkLane()][keyPath: key]
        lanes[workID, default: WorkLane()][keyPath: key] = value
        return previous != value
    }

    func clearLaneFlag(_ key: WritableKeyPath<WorkLane, Bool>) {
        for workID in lanes.keys {
            lanes[workID]?[keyPath: key] = false
        }
    }
}
