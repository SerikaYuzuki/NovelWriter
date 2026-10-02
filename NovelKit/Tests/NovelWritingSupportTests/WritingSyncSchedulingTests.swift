import Foundation
import NovelWritingSupport
import Testing

@MainActor
struct WritingSyncSchedulingTests {
    @Test func visibilityForegroundAndAppendWakeImmediately() async throws {
        let clock = SyncTestClock()
        let scheduler = WritingSyncScheduler(now: { clock.now }, sleep: clock.sleep)
        var attempts = 0
        scheduler.attach(contextID: "work", foreground: true) { attempts += 1 }
        #expect(await clock.next() == .zero)
        clock.advance()
        #expect(await clock.next() == .seconds(300))
        #expect(attempts == 1)
        let panel = UUID(), sheet = UUID()
        scheduler.setVisible(true, token: panel, contextID: "work")
        #expect(await clock.next() == .zero)
        clock.advance()
        #expect(await clock.next() == .seconds(10))
        scheduler.setVisible(true, token: sheet, contextID: "work")
        scheduler.setVisible(false, token: panel, contextID: "work")
        clock.advance()
        #expect(await clock.next() == .seconds(10))
        scheduler.setVisible(false, token: sheet, contextID: "work")
        #expect(await clock.next() == .seconds(300))
        scheduler.recordAppended(contextID: "work")
        #expect(await clock.next() == .zero)
        clock.advance()
        #expect(await clock.next() == .seconds(300))
        let before = attempts
        scheduler.setForeground(false, contextID: "work")
        try await scheduler.synchronize(contextID: "work")
        scheduler.recordAppended(contextID: "work")
        #expect(attempts == before)
        scheduler.setForeground(true, contextID: "work")
        #expect(await clock.next() == .zero)
        clock.advance()
        #expect(await clock.next() == .seconds(300))
        #expect(attempts == before + 1)
        scheduler.detach(contextID: "work")
    }

    @Test func failuresBackOffCapAndSuccessResets() async throws {
        let clock = SyncTestClock()
        let scheduler = WritingSyncScheduler(now: { clock.now }, sleep: clock.sleep)
        var failing = true, attempts = 0
        scheduler.attach(contextID: "work", foreground: true) {
            attempts += 1
            if failing {
                throw WritingError.unavailable
            }
        }
        #expect(await clock.next() == .zero)
        clock.advance()
        #expect(await clock.next() == .seconds(20))
        scheduler.recordAppended(contextID: "work")
        #expect(await clock.next() == .seconds(20))
        await #expect(throws: WritingError.unavailable) { try await scheduler.synchronize(contextID: "work") }
        #expect(attempts == 1)
        for seconds in [40, 80, 160, 320, 600, 600] {
            clock.advance()
            #expect(await clock.next() == .seconds(seconds))
            #expect(scheduler.failed)
        }
        failing = false
        clock.advance()
        #expect(await clock.next() == .seconds(300))
        #expect(!scheduler.failed)
        #expect(scheduler.revision == 1)
        failing = true
        scheduler.recordAppended(contextID: "work")
        #expect(await clock.next() == .zero)
        clock.advance()
        #expect(await clock.next() == .seconds(20))
        scheduler.detach(contextID: "work")
    }

    @Test func concurrentRequestsJoinFlightAndAppendWakesAfterIt() async throws {
        let clock = SyncTestClock()
        let scheduler = WritingSyncScheduler(now: { clock.now }, sleep: clock.sleep)
        var complete: CheckedContinuation<Void, Never>?
        var calls = 0
        scheduler.attach(contextID: "work", foreground: true) {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { complete = $0 }
            }
        }
        #expect(await clock.next() == .zero)
        clock.advance()
        while complete == nil {
            await Task.yield()
        }
        let joined = Task { try await scheduler.synchronize(contextID: "work") }
        await Task.yield()
        scheduler.recordAppended(contextID: "work")
        #expect(calls == 1)
        complete?.resume()
        try await joined.value
        #expect(await clock.next() == .zero)
        clock.advance()
        #expect(await clock.next() == .seconds(300))
        #expect(calls == 2)
        scheduler.detach(contextID: "work")
    }

    @Test func oldContextCompletionCannotResetNewLane() async {
        let clock = SyncTestClock()
        let scheduler = WritingSyncScheduler(now: { clock.now }, sleep: clock.sleep)
        var complete: CheckedContinuation<Void, Never>?
        scheduler.attach(contextID: "old", foreground: true) {
            await withCheckedContinuation { complete = $0 }
        }
        #expect(await clock.next() == .zero)
        clock.advance()
        while complete == nil {
            await Task.yield()
        }
        scheduler.attach(contextID: "new", foreground: true) { throw WritingError.unavailable }
        #expect(await clock.next() == .zero)
        clock.advance()
        #expect(await clock.next() == .seconds(20))
        complete?.resume()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(scheduler.failed)
        #expect(scheduler.revision == 0)
        scheduler.recordAppended(contextID: "old")
        scheduler.setForeground(false, contextID: "old")
        clock.advance()
        #expect(await clock.next() == .seconds(40))
        scheduler.detach(contextID: "new")
    }
}

@MainActor
private final class SyncTestClock {
    var now = Duration.zero
    private var delays: [Duration] = []
    private var sleepers: [(UUID, Duration, CheckedContinuation<Void, Error>)] = []
    private var waiter: CheckedContinuation<Duration, Never>?
    func sleep(_ delay: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError()); return
                }
                sleepers.append((id, now + delay, continuation))
                if let waiter {
                    self.waiter = nil; waiter.resume(returning: delay)
                } else {
                    delays.append(delay)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.0 == id }) else { return }
        sleepers.remove(at: index).2.resume(throwing: CancellationError())
    }

    func next() async -> Duration {
        if !delays.isEmpty {
            return delays.removeFirst()
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    func advance() {
        let earliest = sleepers.map(\.1).min()!
        now = max(now, earliest)
        let ready = sleepers.filter { $0.1 <= now }
        sleepers.removeAll { $0.1 <= now }
        for sleeper in ready {
            sleeper.2.resume()
        }
    }
}
