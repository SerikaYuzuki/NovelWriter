import Foundation

public actor FakeSyncV2RemoteClient: SyncV2RemoteClient {
    public enum Behavior: Sendable {
        case execution(SyncV2RemoteExecution)
        case failure(SyncV2Failure)
        case suspended
    }

    private var behaviors: [Behavior] = [.failure(.offline)]
    private var operations: [SyncV2RemoteOperation] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func setBehaviors(_ behaviors: [Behavior]) {
        self.behaviors = behaviors.isEmpty ? [.failure(.offline)] : behaviors
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
