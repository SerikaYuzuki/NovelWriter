import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

struct HistoryPresentationTests {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func item(_ reason: String, _ time: String, pinned: Bool = false) throws -> SyncV2HistoryItem {
        try SyncV2HistoryItem(occurrenceID: UUID(), snapshotID: SnapshotID(rawValue: String(repeating: "a", count: 64)),
                              reason: reason, pinned: pinned, localGeneration: nil, createdAt: date(time),
                              source: .local,
                              localAvailability: .available, onlineAvailability: .unavailable)
    }

    @Test func daysRespectClockTimezoneAndYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let presentation = HistoryPresentation(calendar: calendar, now: date("2026-01-02T01:00:00Z"))
        #expect(presentation.dayTitle(date("2026-01-01T16:00:00Z")) == "今日")
        #expect(presentation.dayTitle(date("2025-12-31T16:00:00Z")) == "昨日")
        #expect(presentation.dayTitle(date("2025-12-30T16:00:00Z")) == "2025年12月31日（水）")
        let autumn = HistoryPresentation(calendar: calendar, now: date("2026-10-02T01:00:00Z"))
        #expect(autumn.dayTitle(date("2026-09-28T01:00:00Z")) == "9月28日（月）")
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(HistoryPresentation(calendar: calendar, now: presentation.now)
            .dayTitle(date("2026-01-01T16:00:00Z")) == "昨日")
    }

    @Test func autosaveRunsBreakAtManualSaveAndMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let presentation = HistoryPresentation(calendar: calendar, now: date("2026-10-02T12:00:00Z"))
        let items = try [
            item("autosave", "2026-10-02T10:31:00Z"),
            item("autosaveLeaf", "2026-10-02T10:01:00Z", pinned: true),
            item("explicit", "2026-10-02T10:00:00Z"),
            item("autosave", "2026-10-02T09:00:00Z"),
            item("autosave", "2026-10-01T23:00:00Z")
        ]
        let days = presentation.days(items.reversed())
        #expect(days.map(\.title) == ["今日", "昨日"])
        #expect(days[0].runs.map { $0.items.count } == [2, 1, 1])
        #expect(presentation.autosaveLabel(days[0].runs[0]) == "自動保存 2件 · 10:01〜10:31・保持あり")
        #expect(days.flatMap(\.runs).flatMap(\.items).map(\.occurrenceID) == items.map(\.occurrenceID))
        #expect(presentation.days([]).isEmpty)
    }

    @Test func labelsNeverExposeRawReasons() throws {
        let presentation = HistoryPresentation()
        for reason in ["explicit", "restore", "conflictResolution", "keepBoth", "preRestore", "preRemoteAdoption",
                       "remoteAdoption", "remoteBaseline", "autosave", "autosaveLeaf", "futureReason"] {
            let entry = try item(reason, "2026-10-02T01:31:00Z", pinned: true)
            #expect(!presentation.label(entry).contains(reason))
            #expect(presentation.subtitle(entry).hasSuffix("・保持"))
            #expect(!entry.historySymbol.isEmpty)
        }
    }
}
