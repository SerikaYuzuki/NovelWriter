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

    @Test func versionDatesUseTodayYesterdayAndShortCalendarDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let presentation = HistoryPresentation(calendar: calendar, now: date("2026-10-04T04:00:00Z"))
        #expect(presentation.versionDate(date("2026-10-04T03:00:00Z")) == "今日 12:00")
        #expect(presentation.versionDate(date("2026-10-03T03:00:00Z")) == "昨日 12:00")
        #expect(presentation.versionDate(date("2026-09-30T03:00:00Z")) == "9月30日 12:00")
    }

    @Test func groupPredecessorUsesOldestOccurrenceAcrossDays() throws {
        let items = try [
            item("autosave", "2026-10-02T10:00:00Z"),
            item("autosave", "2026-10-02T09:00:00Z"),
            item("explicit", "2026-10-01T20:00:00Z")
        ]
        let presentation = HistoryPresentation()
        #expect(presentation.predecessor(of: items[1], in: items) == items[2].snapshotID)
        #expect(presentation.predecessor(of: items[2], in: items) == nil)
        #expect(!presentation.isUnselectedConflictVersion(items[2], in: items))
    }

    @Test func rejectedVersionLabelsRequireConflictEvidence() throws {
        func record(_ reason: String, generation: Int64, digest: String) throws -> SyncV2HistoryItem {
            try SyncV2HistoryItem(occurrenceID: UUID(), snapshotID: SnapshotID(rawValue: String(repeating: digest, count: 64)),
                                  reason: reason, pinned: true, localGeneration: generation,
                                  createdAt: date("2026-10-02T01:31:00Z"), source: .local,
                                  localAvailability: .available, onlineAvailability: .unavailable)
        }
        let presentation = HistoryPresentation()
        let remote = try record("conflictRemote", generation: 7, digest: "b")
        let decision = try record("conflictResolution", generation: 8, digest: "a")
        #expect(presentation.isUnselectedConflictVersion(remote, in: [remote, decision]))
        #expect(!presentation.isUnselectedConflictVersion(remote, in: [remote]))
        let local = try record("conflictLocal", generation: 7, digest: "a")
        let preserved = try record("preRemoteAdoption", generation: 7, digest: "a")
        #expect(presentation.isUnselectedConflictVersion(local, in: [local, preserved]))
        #expect(presentation.isUnselectedConflictVersion(preserved, in: [local, preserved]))
        #expect(!presentation.isUnselectedConflictVersion(preserved, in: [preserved]))
        #expect(!presentation.isUnselectedConflictVersion(decision, in: [remote, decision]))
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
