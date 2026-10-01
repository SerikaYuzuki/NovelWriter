import Foundation

/// Inherited by the import's child tasks. Mutable timing is protected because
/// URLSession delivers byte progress outside the application actor.
public final class ImportProgress: @unchecked Sendable {
    @TaskLocal public static var current: ImportProgress?
    private let lock = NSLock()
    private var latest = ContinuousClock.now

    public init() {}

    public func received() {
        lock.lock()
        latest = .now
        lock.unlock()
    }

    public func remaining(untilStalledFor timeout: Duration) -> Duration {
        lock.lock()
        let last = latest
        lock.unlock()
        return timeout - last.duration(to: .now)
    }
}
