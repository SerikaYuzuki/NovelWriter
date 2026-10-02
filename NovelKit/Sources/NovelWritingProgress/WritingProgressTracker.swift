import Foundation
import NovelCore
import Observation

/// Local device preferences; never part of a document or sync record.
@MainActor
public final class WritingGoalPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func key(_ work: UUID) -> String {
        "fuminiwa.progress.goal.\(work.uuidString.lowercased())"
    }

    public func goal(for work: UUID) -> WritingGoal? {
        guard let bytes = defaults.data(forKey: key(work)), let value = try? JSONDecoder().decode(
            WritingGoal.self,
            from: bytes
        ), value.characters > 0 else { return nil }
        return value
    }

    public func set(_ goal: WritingGoal?, for work: UUID) {
        if let goal, let bytes = try? JSONEncoder().encode(goal) {
            defaults.set(bytes, forKey: key(work))
        } else {
            defaults.removeObject(forKey: key(work))
        }
    }
}

public struct WritingProgressNotice: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let workID: UUID
    public let threshold: Int
    public var message: String {
        "\(WritingThresholds.label(threshold))に到達しました"
    }
}

/// The editor calls manualChange only after its existing session/IME guards.
/// Install and all other changes call synchronize and never contribute daily counts.
@MainActor
@Observable
public final class WritingProgressTracker {
    public private(set) var records = WritingProgressRecords()
    public private(set) var workID: UUID?
    public private(set) var total = 0
    public private(set) var goal: WritingGoal?
    public private(set) var notice: WritingProgressNotice?
    public private(set) var persistenceFailed = false
    public let calendar: WritingCalendar
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let preferences: WritingGoalPreferences
    @ObservationIgnored private var persistence: (any WritingProgressPersistence)?
    @ObservationIgnored private var pending = WritingProgressRecords()
    @ObservationIgnored private var counts: [EpisodeID: (content: String, count: Int)] = [:]
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var uncountedEditorChangeDepth = 0

    public init(
        defaults: UserDefaults,
        calendar: WritingCalendar = WritingCalendar(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        preferences = WritingGoalPreferences(defaults: defaults)
        self.calendar = calendar; self.now = now
    }

    /// Composition schedules local history loading without making startup or manuscript saves wait.
    public func requestConnection(_ store: any WritingProgressPersistence) {
        guard persistence == nil, connectionTask == nil else { return }
        connectionTask = Task { [weak self] in
            await self?.connect(store)
            self?.connectionTask = nil
        }
    }

    /// Failure leaves tracking in memory. Only progress flushing waits for initial history loading.
    public func connect(_ store: any WritingProgressPersistence) async {
        guard persistence == nil else { return }
        persistence = store
        do {
            let stored = try await store.load()
            var merged = stored
            merged.merge(records)
            records = merged
            loaded = true
            persistenceFailed = false
        } catch { persistenceFailed = true }
        scheduleFlush()
    }

    public func install(_ document: NovelDocument, workID: UUID) {
        noticeTask?.cancel(); notice = nil
        if self.workID != workID {
            counts.removeAll(); total = 0
        }
        self.workID = workID
        goal = preferences.goal(for: workID)
        synchronize(document, workID: workID)
    }

    public func synchronize(_ document: NovelDocument, workID: UUID) {
        if self.workID != workID {
            install(document, workID: workID); return
        }
        var next: [EpisodeID: (content: String, count: Int)] = [:]
        var value = 0
        for chapter in document.chapters {
            for episode in chapter.episodes {
                let count = counts[episode.id].flatMap { $0.content == episode.content ? $0.count : nil }
                    ?? ManuscriptMetrics.countCharacters(in: episode.content)
                next[episode.id] = (episode.content, count)
                value += count
            }
        }
        counts = next; total = value
        recordExistingMilestones()
    }

    /// Native AI replacement emits a synchronous onTextChange too. Keep its normal
    /// model/save notification, but exclude it from manual progress without an EditorKit hook.
    public func withUncountedEditorChange(_ change: () -> Bool) -> Bool {
        uncountedEditorChangeDepth += 1
        defer { uncountedEditorChangeDepth -= 1 }
        return change()
    }

    /// Reuse counts only for the current content; repair an unreported document replacement first.
    public func manualChange(document: NovelDocument, workID: UUID, episodeID: EpisodeID, content: String) {
        if self.workID != workID {
            install(document, workID: workID)
        }
        guard let episode = document.episode(episodeID)?.episode, episode.content != content else { return }
        if counts[episodeID]?.content != episode.content {
            // A missed remote/AI install must not become manual progress or a dated milestone.
            synchronize(document, workID: workID)
        }
        let oldCount = counts[episodeID].flatMap { $0.content == episode.content ? $0.count : nil }
            ?? ManuscriptMetrics.countCharacters(in: episode.content)
        let newCount = ManuscriptMetrics.countCharacters(in: content)
        let oldTotal = total
        total += newCount - oldCount
        counts[episodeID] = (content, newCount)
        guard uncountedEditorChangeDepth == 0 else { recordExistingMilestones(); return }
        let timestamp = now()
        let day = calendar.key(timestamp)
        var delta = WritingDay(); delta.record(delta: newCount - oldCount)
        records.days[workID, default: [:]][day, default: WritingDay()].merge(delta)
        pending.days[workID, default: [:]][day, default: WritingDay()].merge(delta)
        let arrivals = WritingThresholds.arrivals(
            old: oldTotal,
            new: total,
            goal: goal?.characters,
            recorded: Set(records.milestones[workID, default: [:]].keys)
        )
        for threshold in arrivals {
            recordMilestone(threshold, date: timestamp)
        }
        if let threshold = arrivals.last, loaded || (persistence == nil && connectionTask == nil) {
            noticeTask?.cancel()
            let value = WritingProgressNotice(workID: workID, threshold: threshold)
            notice = value
            noticeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard self?.notice?.id == value.id else { return }
                self?.notice = nil
            }
        }
        scheduleFlush()
    }

    public func episodeCount(_ id: EpisodeID) -> Int {
        counts[id]?.count ?? 0
    }

    public func days(for work: UUID) -> [String: WritingDay] {
        records.days[work] ?? [:]
    }

    public func milestones(for work: UUID) -> [WritingMilestone] {
        records.milestones[work, default: [:]].values.sorted { $0.threshold < $1.threshold }
    }

    public func setGoal(_ value: WritingGoal?, for work: UUID) {
        preferences.set(value, for: work)
        guard workID == work else { return }
        goal = value
        recordExistingMilestones()
    }

    private func recordExistingMilestones() {
        guard let workID else { return }
        for threshold in WritingThresholds.candidates(through: total, goal: goal?.characters)
            where threshold <= total && records.milestones[workID]?[threshold] == nil {
            recordMilestone(threshold, date: nil)
        }
        scheduleFlush()
    }

    private func recordMilestone(_ threshold: Int, date: Date?) {
        guard let workID else { return }
        let value = WritingMilestone(threshold: threshold, reachedAt: date)
        records.milestones[workID, default: [:]][threshold] = value
        pending.milestones[workID, default: [:]][threshold] = value
    }

    private func scheduleFlush() {
        guard persistence != nil, !pending.isEmpty, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.flushTask = nil
            await self?.flush()
        }
    }

    /// Errors are contained here; manuscript saves never await this operation.
    public func flush() async {
        await connectionTask?.value
        if flushing {
            await withCheckedContinuation { flushWaiters.append($0) }
            if !persistenceFailed {
                await flush()
            }
            return
        }
        guard let persistence, !pending.isEmpty else { return }
        flushing = true
        let batch = pending; pending = WritingProgressRecords()
        do {
            if !loaded {
                var stored = try await persistence.load()
                stored.merge(records)
                records = stored
                loaded = true
            }
            try await persistence.append(batch)
            persistenceFailed = false
        } catch { pending.merge(batch); persistenceFailed = true }
        flushing = false
        let waiters = flushWaiters
        flushWaiters.removeAll()
        waiters.forEach { $0.resume() }
        scheduleFlush()
    }

    public func requestFlush() {
        guard !pending.isEmpty else { return }
        Task { await flush() }
    }
}
