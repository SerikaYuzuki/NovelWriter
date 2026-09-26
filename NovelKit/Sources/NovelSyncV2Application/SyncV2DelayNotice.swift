import Foundation

public enum SyncV2DelayNotice {
    public static func isDelayed(since: Date?, now: Date = Date()) -> Bool {
        guard let since else { return false }
        let age = now.timeIntervalSince(since)
        return age < 0 || age >= 300
    }

    public static func label(progress: SyncV2RemoteProgress, since: Date?, now: Date = Date()) -> String {
        guard isDelayed(since: since, now: now) else { return progress.japaneseLabel }
        if let since, since > now {
            return "未同期の変更があります（時刻を確認できません）"
        }
        return "未同期の変更があります・\(progress.japaneseLabel)"
    }
}

/// Advances from a wall-clock anchor using monotonic elapsed time while a view
/// is alive. Persisted intent dates still work after restarting the process.
public struct SyncV2DelayClock: Sendable {
    private let wallStart = Date()
    private let monotonicStart = ContinuousClock.now
    public init() {}
    public var now: Date {
        let elapsed = monotonicStart.duration(to: .now).components
        let expected = wallStart.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        // A backwards clock is surfaced as uncertain, never as received.
        return Date().addingTimeInterval(5) < expected ? .distantPast : expected
    }
}
