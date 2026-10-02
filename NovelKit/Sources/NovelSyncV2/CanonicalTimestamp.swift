import Foundation

/// ISO8601DateFormatter is mutable; all access, including across store actors,
/// is serialized. No formatter escapes this cache.
public enum CanonicalTimestamp {
    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        let formatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            return formatter
        }()
    }

    public static func string(_ date: Date) -> String {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return cache.formatter.string(from: date)
    }

    public static func date(_ string: String) -> Date? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return cache.formatter.date(from: string)
    }
}
