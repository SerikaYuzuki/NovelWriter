import Foundation

public struct ImportPhase: Equatable, Sendable {
    public enum Stage: Int, Sendable { case receiving, checking, saving, opening }
    public let stage: Stage
    public let receivedBytes: Int64
    public let totalBytes: Int64?

    public init(stage: Stage = .receiving, receivedBytes: Int64 = 0, totalBytes: Int64? = nil) {
        self.stage = stage
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

/// Task-local progress shared by network callbacks and installation. Wire byte
/// callbacks refresh the stall deadline; raw payload high-water marks exclude retry overhead.
public final class ImportProgress: @unchecked Sendable {
    @TaskLocal public static var current: ImportProgress?
    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var latest: ContinuousClock.Instant
    private var emitted: ContinuousClock.Instant?
    private var phase = ImportPhase()
    private var objectBytes: [ObjectID: Int64] = [:]
    private var finished = false
    public let updates: AsyncStream<ImportPhase>
    private let continuation: AsyncStream<ImportPhase>.Continuation

    public convenience init() {
        self.init(now: { .now })
    }

    /// The stall deadline reads `now`; the application injects its import clock.
    package convenience init(now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.init(now: now, bufferingPolicy: .bufferingNewest(1))
    }

    init(now: @escaping @Sendable () -> ContinuousClock.Instant,
         bufferingPolicy: AsyncStream<ImportPhase>.Continuation.BufferingPolicy) {
        self.now = now
        latest = now()
        emitted = latest
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: bufferingPolicy)
        continuation.yield(phase)
    }

    public var value: ImportPhase {
        lock.lock()
        defer { lock.unlock() }
        return phase
    }

    public func received() {
        lock.lock()
        latest = now()
        lock.unlock()
    }

    public func advance(to stage: ImportPhase.Stage? = nil, bytes: Int64 = 0, total: Int64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        updateLocked(to: stage, bytes: bytes, total: total)
    }

    /// Per-object high-water marks keep retry traffic from inflating progress.
    public func receivedObject(_ id: ObjectID, bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        latest = now()
        let previous = objectBytes[id, default: 0]
        let received = max(previous, bytes)
        objectBytes[id] = received
        updateLocked(to: nil, bytes: received - previous, total: nil)
    }

    private func updateLocked(to stage: ImportPhase.Stage?, bytes: Int64, total: Int64?) {
        guard !finished else { return }
        let next = stage ?? phase.stage
        guard next.rawValue >= phase.stage.rawValue else { return }
        let changed = next != phase.stage
        phase = ImportPhase(stage: next, receivedBytes: phase.receivedBytes + max(0, bytes),
                            totalBytes: total ?? phase.totalBytes)
        let now = now()
        if changed || emitted.map({ $0.duration(to: now) >= .milliseconds(100) }) ?? true {
            emitted = now
            continuation.yield(phase)
        }
    }

    public func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.yield(phase)
        continuation.finish()
    }

    public func remaining(untilStalledFor timeout: Duration) -> Duration {
        lock.lock()
        let last = latest
        lock.unlock()
        return timeout - last.duration(to: now())
    }
}
