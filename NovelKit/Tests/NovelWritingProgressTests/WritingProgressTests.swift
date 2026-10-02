import Foundation
import NovelCore
@testable import NovelWritingProgress
import Testing

private func localCalendar(_ zone: String = "Asia/Tokyo") -> WritingCalendar {
    WritingCalendar(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: zone)!)
}

private func instant(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private func manuscript(_ content: String) -> NovelDocument {
    var document = NovelDocument.newDocument()
    document.updateEpisodeContent(content, for: document.chapters[0].episodes[0].id, in: document.chapters[0].id)
    return document
}

private func defaults() -> UserDefaults {
    UserDefaults(suiteName: "WritingProgressTests.\(UUID())")!
}

@Suite("WritingProgress")
struct WritingProgressTests {
    @Test func additionDeletionAndReplacement() {
        var day = WritingDay()
        day.record(delta: 10); day.record(delta: -4); day.record(delta: 0); day.record(delta: 2)
        #expect(day == WritingDay(added: 12, net: 8))
    }

    @Test func localMidnightAndTimeZones() throws {
        let before = instant("2026-10-01T14:59:59Z"), after = instant("2026-10-01T15:00:00Z")
        #expect(localCalendar().key(before) == "2026-10-01")
        #expect(localCalendar().key(after) == "2026-10-02")
        #expect(localCalendar("America/Los_Angeles").key(after) == "2026-10-01")
        // Civil days remain one day across the DST transition.
        let losAngeles = localCalendar("America/Los_Angeles")
        #expect(try losAngeles.days(
            from: #require(losAngeles.date("2026-03-08")),
            to: #require(losAngeles.date("2026-03-09"))
        ) == 1)
    }

    @Test func relaxedStreakCountsWritingDays() throws {
        let calendar = localCalendar(), now = try #require(calendar.date("2026-10-02"))
        let days = [
            "2026-09-27": WritingDay(added: 2),
            "2026-09-29": WritingDay(added: 3),
            "2026-10-01": WritingDay(added: 4)
        ]
        #expect(calendar.streak(days, now: now) == 3)
        #expect(calendar.streak(days, now: calendar.offset(now, days: 1)) == 3) // Today does not break it.
        #expect(calendar.streak(days, now: calendar.offset(now, days: 2)) == 0) // Two completed rest days.
        #expect(calendar
            .streak(["2026-09-28": WritingDay(added: 5), "2026-10-01": WritingDay(added: 1)], now: now) == 1)
        #expect(calendar.streak(["2026-10-02": WritingDay(added: 0, net: -10)], now: now) == 0)
    }

    @Test func weekUsesInjectedCalendar() throws {
        var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2
        let calendar = WritingCalendar(calendar: cal, timeZone: TimeZone(identifier: "Asia/Tokyo"))
        let days = [
            "2026-09-27": WritingDay(added: 1),
            "2026-09-28": WritingDay(added: 1),
            "2026-10-02": WritingDay(added: 1)
        ]
        #expect(try calendar.thisWeek(days, now: #require(calendar.date("2026-10-02"))) == 2)
    }

    @Test func goalsIncludeTodayAndRoundUp() throws {
        let calendar = localCalendar(), today = try #require(calendar.date("2026-10-02"))
        let goal = try #require(WritingGoal(characters: 10, deadline: "2026-10-04"))
        let status = goal.status(current: 3, now: today, calendar: calendar)
        #expect(status.remaining == 7)
        #expect(status.daysRemaining == 3)
        #expect(status.dailyRequired == 3)
        #expect(!status.overdue)
        let largeGoal = try #require(WritingGoal(characters: Int.max, deadline: "2026-10-02"))
        #expect(largeGoal.status(current: 0, now: today, calendar: calendar).dailyRequired == Int.max)
        #expect(WritingGoal(characters: 0) == nil)
        #expect(WritingGoal(characters: -1) == nil)
        #expect(WritingGoal(characters: 10, deadline: "2026-10-02")?.status(current: 1, now: today, calendar: calendar)
            .dailyRequired == 9)
        #expect(WritingGoal(characters: 10)?.status(current: 1, now: today, calendar: calendar).daysRemaining == nil)
        #expect(goal.status(current: 12, now: today, calendar: calendar).achieved)
        #expect(goal.status(current: 12, now: today, calendar: calendar).fraction == 1)
        let expired = try #require(WritingGoal(characters: 10, deadline: "2026-10-01"))
        #expect(expired.status(current: 1, now: today, calendar: calendar).overdue)
        #expect(expired.status(current: 10, now: today, calendar: calendar).achieved)
        #expect(!expired.status(current: 10, now: today, calendar: calendar).overdue)
    }

    @Test func crossingIsOneTimeAndIncludesGoal() {
        #expect(WritingThresholds.arrivals(old: 9999, new: 10000, goal: nil, recorded: []) == [10000])
        #expect(WritingThresholds.arrivals(old: 10000, new: 10001, goal: nil, recorded: []) == [])
        #expect(WritingThresholds.arrivals(old: 9999, new: 10000, goal: nil, recorded: [10000]) == [])
        #expect(WritingThresholds.arrivals(old: 100, new: 125, goal: 120, recorded: []) == [120])
        #expect(WritingThresholds.candidates(through: 410_000, goal: 100_000).filter { $0 > 200_000 } == [
            300_000,
            400_000,
            500_000
        ])
    }

    @Test @MainActor func manualEntryOnlyAndCachedCounts() throws {
        let clock = localCalendar(), time = try #require(clock.date("2026-10-02")), work = UUID()
        let tracker = WritingProgressTracker(defaults: defaults(), calendar: clock, now: { time })
        var document = manuscript("あいう\nえ")
        let episode = document.chapters[0].episodes[0].id, chapter = document.chapters[0].id
        tracker.install(document, workID: work)
        #expect(tracker.total == 4)
        for content in ["あいうえおか\n", "あい", "うえ", "うえお"] {
            tracker.manualChange(document: document, workID: work, episodeID: episode, content: content)
            document.updateEpisodeContent(content, for: episode, in: chapter)
            tracker.synchronize(document, workID: work)
        }
        #expect(tracker.days(for: work)["2026-10-02"] == WritingDay(added: 3, net: -1))
        #expect(tracker.episodeCount(episode) == 3)
        // AI/MCP and its Undo only synchronize; open/import/remote install only install.
        document.updateEpisodeContent(String(repeating: "文", count: 10100), for: episode, in: chapter)
        tracker.synchronize(document, workID: work)
        #expect(tracker.days(for: work)["2026-10-02"] == WritingDay(added: 3, net: -1))
        #expect(tracker.milestones(for: work).first?.reachedAt == nil)
        #expect(tracker.notice == nil)
        tracker.install(document, workID: work)
        #expect(tracker.days(for: work)["2026-10-02"]?.added == 3)
        let other = UUID(); tracker.install(document, workID: other)
        #expect(tracker.days(for: other).isEmpty)
        #expect(tracker.milestones(for: other).first?.reachedAt == nil)
    }

    @Test(arguments: ["install", "synchronize", "omitted"])
    @MainActor func remoteReplacementThenManualCharacter(refresh: String) throws {
        let clock = localCalendar(), time = try #require(clock.date("2026-10-02")), work = UUID()
        let tracker = WritingProgressTracker(defaults: defaults(), calendar: clock, now: { time })
        var document = manuscript("")
        let chapter = document.chapters[0].id, episode = document.chapters[0].episodes[0].id
        let addedEpisode = document.addEpisode(to: chapter)
        let other = try #require(addedEpisode)
        tracker.install(document, workID: work)
        // Both episodes change while the work stays open. Repair must refresh the whole total.
        let remoteContent = String(repeating: "文", count: 9999)
        document.updateEpisodeContent(remoteContent, for: episode, in: chapter)
        document.updateEpisodeContent("別", for: other, in: chapter)
        switch refresh {
        case "install": tracker.install(document, workID: work)
        case "synchronize": tracker.synchronize(document, workID: work)
        default: break // Simulate a replacement path that forgot to notify the tracker.
        }
        tracker.manualChange(document: document, workID: work, episodeID: episode, content: remoteContent + "一")
        #expect(tracker.days(for: work)["2026-10-02"] == WritingDay(added: 1, net: 1))
        #expect(tracker.total == 10001)
        #expect(tracker.episodeCount(other) == 1)
        #expect(tracker.milestones(for: work).count == 1)
        #expect(tracker.milestones(for: work).first?.reachedAt == nil)
        #expect(tracker.notice == nil)
    }

    @Test @MainActor func manualCrossingAndRecrossing() throws {
        let work = UUID(), clock = localCalendar(), time = try #require(clock.date("2026-10-02"))
        let tracker = WritingProgressTracker(defaults: defaults(), calendar: clock, now: { time })
        var doc = manuscript(String(repeating: "文", count: 9999))
        let episode = doc.chapters[0].episodes[0].id, chapter = doc.chapters[0].id
        tracker.install(doc, workID: work)
        tracker.setGoal(WritingGoal(characters: 10001), for: work)
        for count in [10001, 9999, 10001] {
            let content = String(repeating: "文", count: count)
            tracker.manualChange(document: doc, workID: work, episodeID: episode, content: content)
            doc.updateEpisodeContent(content, for: episode, in: chapter)
        }
        #expect(tracker.milestones(for: work).count == 2)
        #expect(tracker.milestones(for: work).allSatisfy { $0.reachedAt == time })
        #expect(tracker.days(for: work)["2026-10-02"]?.added == 4) // Redo adds again.
        #expect(tracker.notice?.threshold == 10001)
        tracker.install(doc, workID: UUID())
        #expect(tracker.notice == nil)
    }

    @Test @MainActor func injectedClockSplitsDays() {
        let work = UUID(), calendar = localCalendar()
        var time = instant("2026-10-01T14:59:59Z")
        let tracker = WritingProgressTracker(defaults: defaults(), calendar: calendar, now: { time })
        var doc = manuscript(""); let episode = doc.chapters[0].episodes[0].id
        tracker.install(doc, workID: work)
        tracker.manualChange(document: doc, workID: work, episodeID: episode, content: "一")
        doc.updateEpisodeContent("一", for: episode, in: doc.chapters[0].id)
        time = instant("2026-10-01T15:00:00Z")
        tracker.manualChange(document: doc, workID: work, episodeID: episode, content: "一二")
        #expect(tracker.days(for: work)["2026-10-01"]?.added == 1)
        #expect(tracker.days(for: work)["2026-10-02"]?.added == 1)
    }

    @Test @MainActor func goalPreferencesRoundTripAndDelete() throws {
        let prefs = defaults(), work = UUID(), other = UUID()
        let tracker = WritingProgressTracker(defaults: prefs)
        tracker.install(manuscript(String(repeating: "文", count: 15)), workID: work)
        let goal = try #require(WritingGoal(characters: 10, deadline: "2026-10-04"))
        tracker.setGoal(goal, for: work)
        #expect(tracker.notice == nil)
        #expect(tracker.milestones(for: work).first?.reachedAt == nil)
        let reopened = WritingProgressTracker(defaults: prefs)
        reopened.install(manuscript(""), workID: work)
        #expect(reopened.goal == goal)
        reopened.install(manuscript(""), workID: other)
        #expect(reopened.goal == nil)
        tracker.setGoal(nil, for: work)
        reopened.install(manuscript(""), workID: work)
        #expect(reopened.goal == nil)
    }

    @Test func sqliteRoundTripAndAdditiveTransactions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WritingProgressSQLiteStore(root: root), work = UUID()
        var batch = WritingProgressRecords()
        batch.days[work] = ["2026-10-02": WritingDay(added: 100, net: -20)]
        batch.milestones[work] = [10000: WritingMilestone(threshold: 10000, reachedAt: nil),
                                  30000: WritingMilestone(threshold: 30000, reachedAt: instant("2026-10-02T01:00:00Z"))]
        try await store.append(batch)
        try await store.append(batch)
        let reopened = WritingProgressSQLiteStore(root: root)
        let values = try await reopened.load()
        #expect(values.days[work]?["2026-10-02"] == WritingDay(added: 200, net: -40))
        #expect(values.milestones[work]?[10000]?.reachedAt == nil)
        #expect(values.milestones[work]?[30000]?.reachedAt == instant("2026-10-02T01:00:00Z"))
        #expect(values.milestones[work]?.count == 2)
    }

    @Test @MainActor func backgroundConnectionDoesNotBlockEditingAndFlushMergesHistoryOnce() async throws {
        let calendar = localCalendar(), time = try #require(calendar.date("2026-10-02")), work = UUID()
        var history = WritingProgressRecords()
        history.days[work] = ["2026-10-02": WritingDay(added: 10, net: 10)]
        history.milestones[work] = [10000: WritingMilestone(threshold: 10000, reachedAt: time)]
        let persistence = SuspendedReadProgressStore(history)
        let tracker = WritingProgressTracker(defaults: defaults(), calendar: calendar, now: { time })
        tracker.requestConnection(persistence)
        await persistence.waitForLoad()
        // Initial DB reading remains suspended while the editor can install and type.
        let document = manuscript(String(repeating: "文", count: 9999))
        tracker.install(document, workID: work)
        tracker.manualChange(document: document, workID: work, episodeID: document.chapters[0].episodes[0].id,
                             content: String(repeating: "文", count: 10000))
        #expect(tracker.total == 10000)
        #expect(tracker.days(for: work)["2026-10-02"] == WritingDay(added: 1, net: 1))
        #expect(tracker.notice == nil) // History is not loaded, so an old milestone cannot notify again.
        let flush = Task { await tracker.flush() }
        await persistence.release()
        await flush.value
        #expect(tracker.days(for: work)["2026-10-02"] == WritingDay(added: 11, net: 11))
        #expect(tracker.milestones(for: work).first?.reachedAt == time)
        let saved = await persistence.savedRecords()
        #expect(saved.days[work]?["2026-10-02"] == WritingDay(added: 11, net: 11))
        #expect(saved.milestones[work]?[10000]?.reachedAt == time)
    }

    @Test @MainActor func failureIsContainedAndPendingBatchRetries() async throws {
        let store = FailingProgressStore(), work = UUID(), tracker = WritingProgressTracker(defaults: defaults())
        await tracker.connect(store)
        var doc = manuscript(""); let episode = doc.chapters[0].episodes[0].id
        tracker.install(doc, workID: work)
        tracker.manualChange(document: doc, workID: work, episodeID: episode, content: "abc")
        await tracker.flush()
        #expect(tracker.persistenceFailed)
        #expect(tracker.total == 3)
        await store.recover()
        doc.updateEpisodeContent("abc", for: episode, in: doc.chapters[0].id)
        tracker.manualChange(document: doc, workID: work, episodeID: episode, content: "abcd")
        await tracker.flush()
        #expect(!tracker.persistenceFailed)
        let saved = try await store.load()
        #expect(saved.days[work]?.values.first?.added == 4)
        await tracker.flush()
        let unchanged = try await store.load()
        #expect(unchanged.days[work]?.values.first?.added == 4)
    }

    @Test @MainActor func flushWaitsForInflightBatchAndCapturesNewEdits() async throws {
        let persistence = SuspendedProgressStore(), tracker = WritingProgressTracker(defaults: defaults()),
            work = UUID()
        await tracker.connect(persistence)
        var document = manuscript("")
        let episode = document.chapters[0].episodes[0].id
        tracker.install(document, workID: work)
        tracker.manualChange(document: document, workID: work, episodeID: episode, content: "abc")
        let first = Task { await tracker.flush() }
        await persistence.waitForAppend()
        document.updateEpisodeContent("abc", for: episode, in: document.chapters[0].id)
        tracker.manualChange(document: document, workID: work, episodeID: episode, content: "abcd")
        let suspension = Task { await tracker.flush() }
        await persistence.release()
        await first.value
        await suspension.value
        let saved = try await persistence.load()
        #expect(saved.days[work]?.values.first?.added == 4)
    }

    @Test @MainActor func failedReadRecoversWithoutOverwritingHistoryOrRepeatingNotice() async throws {
        let calendar = localCalendar(), time = try #require(calendar.date("2026-10-02")), work = UUID()
        var existing = WritingProgressRecords()
        existing.days[work] = ["2026-10-02": WritingDay(added: 10, net: 10)]
        existing.milestones[work] = [10000: WritingMilestone(threshold: 10000, reachedAt: time)]
        let persistence = RecoveringReadProgressStore(records: existing)
        let tracker = WritingProgressTracker(defaults: defaults(), calendar: calendar, now: { time })
        await tracker.connect(persistence)
        let document = manuscript(String(repeating: "文", count: 9999))
        tracker.install(document, workID: work)
        tracker.manualChange(
            document: document,
            workID: work,
            episodeID: document.chapters[0].episodes[0].id,
            content: String(repeating: "文", count: 10001)
        )
        #expect(tracker.notice == nil)
        await tracker.flush()
        #expect(!tracker.persistenceFailed)
        #expect(tracker.days(for: work)["2026-10-02"]?.added == 12)
        #expect(tracker.milestones(for: work).first?.reachedAt == time)
        let saved = try await persistence.load()
        #expect(saved.days[work]?["2026-10-02"]?.added == 12)
    }

    @Test @MainActor func unavailableSQLiteCannotThrowIntoEditing() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let tracker = WritingProgressTracker(defaults: defaults()), work = UUID(), doc = manuscript("")
        await tracker.connect(WritingProgressSQLiteStore(root: file))
        tracker.install(doc, workID: work)
        tracker.manualChange(document: doc, workID: work, episodeID: doc.chapters[0].episodes[0].id, content: "本文")
        await tracker.flush()
        #expect(tracker.total == 2)
        #expect(tracker.persistenceFailed)
    }
}

private actor FailingProgressStore: WritingProgressPersistence {
    var failing = true
    var records = WritingProgressRecords()
    func recover() {
        failing = false
    }

    func load() throws -> WritingProgressRecords {
        records
    }

    func append(_ batch: WritingProgressRecords) throws {
        if failing {
            throw WritingProgressStoreError.unavailable
        }
        records.merge(batch)
    }
}

private actor SuspendedProgressStore: WritingProgressPersistence {
    var records = WritingProgressRecords()
    var appending = false
    var appendWaiter: CheckedContinuation<Void, Never>?
    var startWaiter: CheckedContinuation<Void, Never>?
    func load() throws -> WritingProgressRecords {
        records
    }

    func waitForAppend() async {
        if !appending {
            await withCheckedContinuation { startWaiter = $0 }
        }
    }

    func release() {
        appendWaiter?.resume(); appendWaiter = nil
    }

    func append(_ batch: WritingProgressRecords) async throws {
        if !appending {
            appending = true
            await withCheckedContinuation {
                appendWaiter = $0
                startWaiter?.resume(); startWaiter = nil
            }
        }
        records.merge(batch)
    }
}

private actor RecoveringReadProgressStore: WritingProgressPersistence {
    var records: WritingProgressRecords
    var firstRead = true
    init(records: WritingProgressRecords) {
        self.records = records
    }

    func load() throws -> WritingProgressRecords {
        if firstRead {
            firstRead = false; throw WritingProgressStoreError.unavailable
        }
        return records
    }

    func append(_ batch: WritingProgressRecords) throws {
        records.merge(batch)
    }
}

private actor SuspendedReadProgressStore: WritingProgressPersistence {
    private var records: WritingProgressRecords
    private var started = false
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    init(_ records: WritingProgressRecords) {
        self.records = records
    }

    func load() async -> WritingProgressRecords {
        started = true
        await withCheckedContinuation {
            loadWaiter = $0
            startWaiter?.resume(); startWaiter = nil
        }
        return records
    }

    func waitForLoad() async {
        if started {
            return
        }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        loadWaiter?.resume(); loadWaiter = nil
    }

    func append(_ batch: WritingProgressRecords) {
        records.merge(batch)
    }

    func savedRecords() -> WritingProgressRecords {
        records
    }
}
