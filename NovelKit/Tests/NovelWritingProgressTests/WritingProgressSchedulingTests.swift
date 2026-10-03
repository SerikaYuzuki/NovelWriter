import Foundation
import NovelCore
@testable import NovelWritingProgress
import Observation
import Testing

@MainActor
struct WritingProgressSchedulingTests {
    @Test func manualChangesPublishOnceAndKeepOtherEpisodeCache() async throws {
        let tracker = try WritingProgressTracker(defaults: #require(UserDefaults(suiteName: UUID().uuidString)))
        var document = NovelDocument.newDocument()
        document.chapters = [Chapter(title: "章", episodes: [Episode(content: ""), Episode(content: "別")])]
        let work = UUID(), chapter = document.chapters[0].id, episode = document.chapters[0].episodes[0].id
        let other = document.chapters[0].episodes[1].id
        tracker.install(document, workID: work)
        let notifications = ProgressNotificationCounter()
        withObservationTracking { _ = tracker.records; _ = tracker.total } onChange: { notifications.increment() }
        // A sentinel detects an unintended all-episode synchronize on the manual path.
        document.updateEpisodeContent("別の変更", for: other, in: chapter)
        for index in 1 ... 200 {
            let previous = document.chapters[0].episodes[0].content
            let content = String(repeating: "文", count: index)
            tracker.manualChange(document: document, workID: work, episodeID: episode,
                                 content: content, previousContent: previous)
            document.updateEpisodeContent(content, for: episode, in: chapter)
        }
        #expect(notifications.value == 0)
        #expect(tracker.total == 1)
        #expect(tracker.records.days.isEmpty)
        #expect(tracker.episodeCount(other) == 1)
        await tracker.flush() // Publication also works without a persistence connection.
        #expect(notifications.value == 1)
        #expect(tracker.total == 201)
        #expect(tracker.days(for: work).values.first?.added == 200)
        let unchanged = ProgressNotificationCounter()
        withObservationTracking { _ = tracker.total; _ = tracker.records } onChange: { unchanged.increment() }
        tracker.publishSnapshot()
        #expect(unchanged.value == 0)
        // The non-manual boundary still repairs all episodes.
        tracker.synchronize(document, workID: work)
        #expect(tracker.episodeCount(other) == 4)
        #expect(tracker.total == 204)
    }

    @Test func publicationArrivesWithinThreeSecondsWithoutPersistence() async throws {
        let clock = ProgressTestClock()
        let tracker = try WritingProgressTracker(defaults: #require(UserDefaults(suiteName: UUID().uuidString)), sleep: clock.sleep)
        let document = NovelDocument.newDocument(), work = UUID()
        tracker.install(document, workID: work)
        tracker.manualChange(document: document, workID: work, episodeID: document.chapters[0].episodes[0].id,
                             content: "文")
        #expect(await clock.scheduled(0) == .seconds(3))
        #expect(tracker.total == 0)
        #expect(tracker.days(for: work).isEmpty)
        // Register before advancing, then await publication itself rather than elapsed wall time.
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = tracker.total } onChange: { continuation.resume() }
            clock.advance()
        }
        #expect(tracker.total == 1)
        #expect(tracker.days(for: work).values.first?.added == 1)
    }

    @Test func automaticRetriesBackOffCapAndRecover() async throws {
        let clock = ProgressTestClock(), store = RetryProgressStore()
        let tracker = try WritingProgressTracker(defaults: #require(UserDefaults(suiteName: UUID().uuidString)), sleep: clock.sleep)
        await tracker.connect(store)
        var document = NovelDocument.newDocument()
        let work = UUID(), episode = document.chapters[0].episodes[0].id
        tracker.install(document, workID: work)
        tracker.manualChange(document: document, workID: work, episodeID: episode, content: "文")
        tracker.publishSnapshot() // Cancel publication so this clock measures persistence retries only.
        for (index, seconds) in [3, 6, 12, 24, 48, 96, 180, 180].enumerated() {
            let delay = await clock.scheduled(index)
            #expect(delay == .seconds(seconds))
            if index == 1 {
                document.updateEpisodeContent("文", for: episode, in: document.chapters[0].id)
                tracker.manualChange(document: document, workID: work, episodeID: episode, content: "文章")
                tracker.publishSnapshot()
                // New input must not reset the outstanding retry or its backoff.
                #expect(clock.delays.count == 2)
            }
            if index == 7 {
                await store.recover()
            }
            clock.advance()
        }
        await store.waitForSuccess()
        #expect(await store.attempts == 8)
        #expect(await store.saved.days[work]?.values.first?.added == 2)
        // Let the successful append's main-actor completion clear the failure flag.
        await tracker.flush()
        #expect(!tracker.persistenceFailed)
        document.updateEpisodeContent("文章", for: episode, in: document.chapters[0].id)
        tracker.manualChange(document: document, workID: work, episodeID: episode, content: "文章次")
        tracker.publishSnapshot()
        #expect(await clock.scheduled(8) == .seconds(3))
        clock.advance()
        await tracker.flush()
    }

    @Test(arguments: [false, true])
    func unsupportedVersionStopsRetriesButRetainsMemory(failsOnLoad: Bool) async throws {
        let clock = ProgressTestClock(), store = PermanentProgressStore(failsOnLoad: failsOnLoad)
        let tracker = try WritingProgressTracker(defaults: #require(UserDefaults(suiteName: UUID().uuidString)), sleep: clock.sleep)
        await tracker.connect(store)
        var document = NovelDocument.newDocument()
        let work = UUID(), episode = document.chapters[0].episodes[0].id
        tracker.install(document, workID: work)
        tracker.manualChange(document: document, workID: work, episodeID: episode, content: "文")
        tracker.publishSnapshot() // Isolate persistence retries from the publication timer.
        if !failsOnLoad {
            #expect(await clock.scheduled(0) == .seconds(3))
            clock.advance()
        }
        await tracker.flush()
        #expect(tracker.persistenceRetryStopped)
        #expect(tracker.persistenceFailed)
        document.updateEpisodeContent("文", for: episode, in: document.chapters[0].id)
        tracker.manualChange(document: document, workID: work, episodeID: episode, content: "文章")
        tracker.requestFlush()
        await tracker.flush()
        #expect(tracker.total == 2)
        #expect(tracker.days(for: work).values.first?.added == 2)
        #expect(await store.loads == 1)
        #expect(await store.appends == (failsOnLoad ? 0 : 1))
        #expect(clock.delays.count == (failsOnLoad ? 0 : 1))
    }
}

private final class ProgressNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

@MainActor
private final class ProgressTestClock {
    var delays: [Duration] = []
    private var sleepers: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var waiter: CheckedContinuation<Duration, Never>?
    func sleep(_ delay: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        delays.append(delay)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append((id, continuation))
                    waiter?.resume(returning: delay); waiter = nil
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.0 == id }) else { return }
        sleepers.remove(at: index).1.resume(throwing: CancellationError())
    }

    func scheduled(_ index: Int) async -> Duration {
        if delays.count > index {
            return delays[index]
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    func advance() {
        sleepers.removeFirst().1.resume()
    }
}

private actor RetryProgressStore: WritingProgressPersistence {
    var attempts = 0
    var saved = WritingProgressRecords()
    private var failing = true
    private var successWaiter: CheckedContinuation<Void, Never>?
    func load() -> WritingProgressRecords {
        saved
    }

    func recover() {
        failing = false
    }

    func append(_ batch: WritingProgressRecords) throws {
        attempts += 1
        if failing {
            throw WritingProgressStoreError.unavailable
        }
        saved.merge(batch)
        successWaiter?.resume(); successWaiter = nil
    }

    func waitForSuccess() async {
        if saved.isEmpty {
            await withCheckedContinuation { successWaiter = $0 }
        }
    }
}

private actor PermanentProgressStore: WritingProgressPersistence {
    let failsOnLoad: Bool
    var loads = 0, appends = 0
    init(failsOnLoad: Bool) {
        self.failsOnLoad = failsOnLoad
    }

    func load() throws -> WritingProgressRecords {
        loads += 1
        if failsOnLoad {
            throw WritingProgressStoreError.unsupportedVersion
        }
        return WritingProgressRecords()
    }

    func append(_: WritingProgressRecords) throws {
        appends += 1
        throw WritingProgressStoreError.unsupportedVersion
    }
}
