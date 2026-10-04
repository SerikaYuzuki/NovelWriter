/// macOS document operation の直列化境界。
///
/// v2 の通常 identity は `WorkID` と shared `SyncV2Application` の session
/// token が担う。ここは AppKit/EditorKit の IME・遷移境界を一度に通す
/// FIFO gate だけを提供し、package URL を保存 identity にしない。
@MainActor
public final class DocumentOperationGate {
    /// Signals an enqueued operation after the current owner has acquired the gate.
    private let didEnqueueOperation: (@MainActor () -> Void)?
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(didEnqueueOperation: (@MainActor () -> Void)? = nil) {
        self.didEnqueueOperation = didEnqueueOperation
    }

    public func perform<T>(_ operation: @MainActor () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        guard isRunning else {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            didEnqueueOperation?()
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

/// Serializes the whole auth ownership exchange, not only individual vault
/// calls. A sign-out or later sign-in therefore cannot interleave with an
/// earlier Apple exchange while its response is being committed.
@MainActor
public final class AuthOperationGate {
    public init() {}

    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public func perform<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isRunning else {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}
