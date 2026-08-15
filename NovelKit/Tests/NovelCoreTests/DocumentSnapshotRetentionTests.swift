import Foundation
@testable import NovelCore
import Testing

struct DocumentSnapshotRetentionTests {
    private let now = Self.iso("2026-08-14T12:00:00Z")
    private let calendar = DocumentSnapshotRetention.utcGregorianCalendar

    @Test func recentHourKeepsEveryAutomaticSnapshot() {
        let snapshots = [
            automatic("recent-a", "2026-08-14T11:20:00Z"),
            automatic("recent-b", "2026-08-14T11:40:00Z"),
            automatic("recent-c", "2026-08-14T11:55:00Z")
        ]
        #expect(deletedNames(from: snapshots).isEmpty)
    }

    @Test func hourlyBucketKeepsNewestInTheSameHour() {
        let snapshots = [
            automatic("hour-new", "2026-08-13T15:50:00Z"),
            automatic("hour-old", "2026-08-13T15:10:00Z"),
            automatic("other-hour", "2026-08-13T14:05:00Z")
        ]
        #expect(deletedNames(from: snapshots) == ["hour-old"])
    }

    @Test func dailyBucketKeepsNewestOnTheSameDay() {
        let snapshots = [
            automatic("day-new", "2026-08-01T20:00:00Z"),
            automatic("day-old", "2026-08-01T08:00:00Z"),
            automatic("other-day", "2026-07-20T12:00:00Z")
        ]
        #expect(deletedNames(from: snapshots) == ["day-old"])
    }

    @Test func weeklyBucketKeepsNewestInTheSameISOWeek() {
        let snapshots = [
            automatic("week-new", "2026-06-04T12:00:00Z"),
            automatic("week-old", "2026-06-01T08:00:00Z"),
            automatic("other-week", "2026-05-20T12:00:00Z")
        ]
        #expect(deletedNames(from: snapshots) == ["week-old"])
    }

    @Test func monthlyBucketKeepsNewestInTheSameMonthAfterAYear() {
        let snapshots = [
            automatic("month-new", "2025-03-20T12:00:00Z"),
            automatic("month-old", "2025-03-05T08:00:00Z"),
            automatic("other-month", "2025-02-01T12:00:00Z")
        ]
        #expect(deletedNames(from: snapshots) == ["month-old"])
    }

    @Test func manualSnapshotsAreNeverDeleted() {
        let snapshots = [
            automatic("auto-old", "2026-08-01T08:00:00Z"),
            automatic("auto-new", "2026-08-01T20:00:00Z"),
            manual("manual", "2026-08-01T08:00:00Z")
        ]
        #expect(deletedNames(from: snapshots) == ["auto-old"])
    }

    private func deletedNames(from snapshots: [DocumentSnapshotInfo]) -> [String] {
        DocumentSnapshotRetention.automaticURLsToDelete(
            from: snapshots,
            now: now,
            calendar: calendar
        ).map(\.lastPathComponent)
    }

    private func automatic(_ name: String, _ isoDate: String) -> DocumentSnapshotInfo {
        DocumentSnapshotInfo(
            url: URL(fileURLWithPath: "/snapshots/\(name)"),
            createdAt: Self.iso(isoDate),
            displayName: name,
            isAutomatic: true
        )
    }

    private func manual(_ name: String, _ isoDate: String) -> DocumentSnapshotInfo {
        DocumentSnapshotInfo(
            url: URL(fileURLWithPath: "/snapshots/\(name)"),
            createdAt: Self.iso(isoDate),
            displayName: name,
            isAutomatic: false
        )
    }

    private static func iso(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }
}
