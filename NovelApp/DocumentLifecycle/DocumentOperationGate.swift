import Foundation

/// 非同期操作が、呼び出し時と同じ作品セッションを対象にしているか確認する値。
/// 同じ作品IDでも「別名保存」や復元後はgenerationが変わり、古いUI操作を拒否する。
struct DocumentSessionToken: Hashable, Sendable {
    var generation: UInt64
    var documentID: UUID
    var documentURL: URL
}

/// `AppState`の作品ライフサイクル操作を、`await`をまたいでFIFOに直列化する。
///
/// `AppState`はMainActor上にあるが、Repository I/O中は別Taskが同じ状態へ入れる。
/// 作品の切替・別名保存・復元・資料操作が互いの`documentURL`を読み替えないよう、
/// 高レベル操作の最外周でこのGateを取得する(D-041)。
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
