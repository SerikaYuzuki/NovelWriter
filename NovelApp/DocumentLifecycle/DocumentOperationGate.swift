/// macOS document operation の直列化境界。
///
/// v2 の通常 identity は `WorkID` と shared `SyncV2Application` の session
/// token が担う。ここは AppKit/EditorKit の IME・遷移境界を一度に通す
/// FIFO gate だけを提供し、package URL を保存 identity にしない。
@MainActor
final class DocumentOperationGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<T>(_ operation: @MainActor () async -> T) async -> T {
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
