import Foundation

public struct WritingDay: Codable, Equatable, Sendable {
    public var added: Int = 0
    public var net: Int = 0
    public init(added: Int = 0, net: Int = 0) {
        self.added = added; self.net = net
    }

    public mutating func record(delta: Int) {
        added += max(0, delta); net += delta
    }

    public mutating func merge(_ other: Self) {
        added += other.added; net += other.net
    }
}

public struct WritingMilestone: Codable, Equatable, Identifiable, Sendable {
    public var id: Int {
        threshold
    }

    public let threshold: Int
    public let reachedAt: Date?
    public init(threshold: Int, reachedAt: Date?) {
        self.threshold = threshold; self.reachedAt = reachedAt
    }
}

/// A civil date is stored independently of a timestamp. Calendar/time zone are injectable.
public struct WritingCalendar: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .autoupdatingCurrent, timeZone: TimeZone? = nil) {
        self.calendar = calendar
        if let timeZone {
            self.calendar.timeZone = timeZone
        }
    }

    public func key(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    public func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public func offset(_ date: Date, days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date))!
    }

    public func days(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end))
            .day ?? 0
    }

    public func streak(_ entries: [String: WritingDay], now: Date) -> Int {
        let dates = entries.filter { $0.value.added > 0 }.compactMap { date($0.key) }.filter { $0 <= now }.sorted(by: >)
        guard let latest = dates.first, days(from: latest, to: now) <= 2 else { return 0 }
        var count = 1, previous = latest
        for day in dates.dropFirst() {
            guard days(from: day, to: previous) <= 2 else { break }
            count += 1; previous = day
        }
        return count
    }

    public func thisWeek(_ entries: [String: WritingDay], now: Date) -> Int {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return entries.count(where: { entry in
            guard entry.value.added > 0, let day = date(entry.key) else { return false }
            return day >= interval.start && day < interval.end && day <= now
        })
    }
}

public struct WritingGoal: Codable, Equatable, Sendable {
    public let characters: Int
    public let deadline: String?
    public init?(characters: Int, deadline: String? = nil) {
        guard characters > 0 else { return nil }
        self.characters = characters; self.deadline = deadline
    }

    public func status(current: Int, now: Date, calendar: WritingCalendar) -> WritingGoalStatus {
        let remaining = max(0, characters - current)
        let days = deadline.flatMap { calendar.date($0) }.map { calendar.days(from: now, to: $0) + 1 }
        return WritingGoalStatus(
            fraction: min(1, max(0, Double(current) / Double(characters))),
            remaining: remaining,
            daysRemaining: days,
            dailyRequired: days.flatMap { count in
                guard count > 0 else { return nil }
                return remaining / count + (remaining.isMultiple(of: count) ? 0 : 1)
            }
        )
    }
}

public struct WritingGoalStatus: Equatable, Sendable {
    public let fraction: Double
    public let remaining: Int
    public let daysRemaining: Int?
    public let dailyRequired: Int?
    public var achieved: Bool {
        remaining == 0
    }

    public var overdue: Bool {
        !achieved && (daysRemaining.map { $0 <= 0 } ?? false)
    }
}

public enum WritingThresholds {
    public static func candidates(through total: Int, goal: Int?) -> [Int] {
        var values = [10000, 30000, 50000, 100_000, 150_000, 200_000]
        if total >= 200_000 {
            values += Array(stride(from: 300_000, through: max(300_000, (total / 100_000 + 1) * 100_000), by: 100_000))
        }
        if let goal, goal > 0 {
            values.append(goal)
        }
        return Array(Set(values)).sorted()
    }

    public static func arrivals(old: Int, new: Int, goal: Int?, recorded: Set<Int>) -> [Int] {
        candidates(through: new, goal: goal).filter { old < $0 && $0 <= new && !recorded.contains($0) }
    }

    public static func label(_ value: Int) -> String {
        value.isMultiple(of: 10000) ? "\(value / 10000)万字" : "\(value.formatted())字"
    }
}
