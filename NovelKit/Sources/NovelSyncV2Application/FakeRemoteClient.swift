import Foundation
import NovelSyncV2

public actor FakeSyncV2RemoteClient: SyncV2RemoteClient {
    public typealias CommandHandler = @Sendable (SyncV2SealedRemoteCommand) throws -> SyncV2RemoteExecution

    public enum Behavior: Sendable {
        case execution(SyncV2RemoteExecution)
        case failure(SyncV2Failure)
        case suspended
    }

    private var behaviors: [Behavior] = [.failure(.offline)]
    private var operations: [SyncV2RemoteOperation] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var commandHandler: CommandHandler?

    private var deletionFailure: SyncV2Failure? = .offline
    private var deletions: [WorkID] = []

    public func setDeletionFailure(_ failure: SyncV2Failure?) {
        deletionFailure = failure
    }

    public func recordedDeletions() -> [WorkID] {
        deletions
    }

    public func deleteWork(workID: WorkID, binding _: SyncV2AccountScopeBinding) async throws {
        deletions.append(workID)
        if let deletionFailure {
            throw deletionFailure
        }
    }

    private var headHandler: (@Sendable (WorkID) async throws -> SyncV2RemoteHead?)?
    private var headReads: [WorkID] = []

    public func setHeadHandler(_ handler: @escaping @Sendable (WorkID) async throws -> SyncV2RemoteHead?) {
        headHandler = handler
    }

    public func recordedHeadReads() -> [WorkID] {
        headReads
    }

    public func remoteHead(workID: WorkID) async throws -> SyncV2RemoteHead? {
        headReads.append(workID)
        guard let headHandler else { throw SyncV2Failure.offline }
        return try await headHandler(workID)
    }

    var historyEntries: [WorkID: [SyncV2RemoteHistoryEntry]] = [:]
    var historyBackfillHandler: (@Sendable (WorkID, Bool, @escaping @Sendable () async -> Void) async throws -> Void)?

    public init() {}

    public func setBehaviors(_ behaviors: [Behavior]) {
        self.behaviors = behaviors.isEmpty ? [.failure(.offline)] : behaviors
    }

    /// Installs a deterministic command responder for integration tests. The
    /// handler receives the sealed bytes that the production worker sends, so
    /// tests can build an exact receipt without weakening the outbox path.
    public func setCommandHandler(_ handler: CommandHandler?) {
        commandHandler = handler
    }

    public func recordedOperations() -> [SyncV2RemoteOperation] {
        operations
    }

    public func resumeSuspended() {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    public func execute(
        _ operation: SyncV2RemoteOperation
    ) async throws -> SyncV2RemoteExecution {
        operations.append(operation)
        if case let .command(command) = operation, let commandHandler {
            return try commandHandler(command)
        }
        if case let .upload(transfer) = operation, commandHandler != nil {
            return .upload(
                SyncV2UploadCompletion(
                    transferID: transfer.transferID,
                    uploadID: transfer.uploadID,
                    objectID: transfer.objectID,
                    acknowledgedByteCount: transfer.exactBytes.count
                )
            )
        }
        let behavior = behaviors.count > 1 ? behaviors.removeFirst() : behaviors[0]
        switch behavior {
        case let .execution(execution):
            return execution
        case let .failure(failure):
            throw failure
        case .suspended:
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
            throw SyncV2Failure.retryable(.lostResponse)
        }
    }
}
