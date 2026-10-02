import Foundation
#if os(macOS)
@testable import FUMINIWA
#else
@testable import FUMINIWAIOS
#endif
import NovelCore
import NovelTiming
import Testing

@Suite("Local save revision ownership")
@MainActor
struct V2DocumentSaveCoordinatorTests {
    @Test("typing during an awaited checkpoint is saved in a second checkpoint")
    func savesEditsArrivingDuringCheckpoint() async {
        var document = NovelDocument.newDocument()
        document.title = "before"
        var saved: [String] = []
        var coordinator: V2DocumentSaveCoordinator!
        coordinator = V2DocumentSaveCoordinator(
            timing: FuminiwaTiming(),
            currentDocument: { document },
            saveOperation: { snapshot in
                saved.append(snapshot.title)
                if saved.count == 1 {
                    document.title = "after"
                    coordinator.markDirty()
                    await Task.yield()
                }
            }
        )
        coordinator.markDirty()
        #expect(await coordinator.saveNow())
        #expect(saved == ["before", "after"])
        #expect(await coordinator.saveNow())
        #expect(saved.count == 2)
    }

    @Test("failed follow-up checkpoint remains dirty and is retried")
    func retriesUnsavedFollowUp() async {
        var document = NovelDocument.newDocument()
        document.title = "before"
        var saved: [String] = []
        var attempts = 0
        var coordinator: V2DocumentSaveCoordinator!
        coordinator = V2DocumentSaveCoordinator(
            timing: FuminiwaTiming(),
            currentDocument: { document },
            saveOperation: { snapshot in
                attempts += 1
                if attempts == 2 {
                    throw CocoaError(.fileWriteUnknown)
                }
                saved.append(snapshot.title)
                if attempts == 1 {
                    document.title = "after"
                    coordinator.markDirty()
                }
            }
        )
        coordinator.markDirty()
        #expect(await coordinator.saveNow() == false)
        #expect(saved == ["before"])
        #expect(await coordinator.saveNow())
        #expect(saved == ["before", "after"])
    }

    @Test("debounced autosave does not cancel its own checkpoint")
    func autosaveDoesNotCancelItself() async throws {
        let document = NovelDocument.newDocument()
        var saved = false
        let coordinator = V2DocumentSaveCoordinator(
            timing: FuminiwaTiming(),
            debounceSleep: { _ in await Task.yield() },
            currentDocument: { document },
            saveOperation: { _ in
                try Task.checkCancellation()
                saved = true
            }
        )
        coordinator.markDirty()
        coordinator.scheduleDebouncedSave()
        for _ in 0 ..< 100 where !saved {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(saved)
    }
}

@Suite("Autosave debounce after in-flight edits")
@MainActor
struct AutosaveFollowUpTests {
    @Test
    func continuedTypingWaitsForTwoSecondsOfIdle() async {
        let clock = SaveDebounceClock()
        var document = NovelDocument.newDocument()
        var saved: [String] = []
        var finishFirst: CheckedContinuation<Void, Never>?
        let coordinator = V2DocumentSaveCoordinator(
            timing: FuminiwaTiming(), debounceSleep: { try await clock.sleep($0) },
            currentDocument: { document }, saveOperation: { snapshot in
                saved.append(snapshot.title)
                if saved.count == 1 {
                    await withCheckedContinuation { finishFirst = $0 }
                }
            }
        )
        coordinator.markDirty()
        coordinator.scheduleDebouncedSave()
        await settle { clock.waitingCount == 1 }
        clock.advance(2_000_000_000)
        await settle { saved.count == 1 && finishFirst != nil }
        clock.advance(500_000_000)
        document.title = "入力継続"
        coordinator.markDirty()
        coordinator.scheduleDebouncedSave()
        await settle { clock.waitingCount == 1 }
        clock.advance(500_000_000)
        finishFirst?.resume()
        await settle { coordinator.lastSavedRevision == 1 }
        #expect(saved.count == 1)
        clock.advance(1_490_000_000)
        await Task.yield()
        #expect(saved.count == 1)
        clock.advance(10_000_000)
        await settle { saved.count == 2 }
        #expect(saved.last == "入力継続")
        #expect(await coordinator.saveNow())
        #expect(coordinator.lastSavedRevision == 2)
    }

    @Test
    func injectedDebounceAndBlockedSaveWaitAreIndependent() async {
        let clock = SaveDebounceClock()
        var saved = 0
        var finishFirst: CheckedContinuation<Void, Never>?
        let coordinator = V2DocumentSaveCoordinator(
            timing: FuminiwaTiming(autosaveDebounceSeconds: 1, autosavePostSaveWaitSeconds: 4),
            debounceSleep: { try await clock.sleep($0) },
            currentDocument: { NovelDocument.newDocument() }, saveOperation: { _ in
                saved += 1
                if saved == 1 {
                    await withCheckedContinuation { finishFirst = $0 }
                }
            }
        )
        coordinator.markDirty()
        coordinator.scheduleDebouncedSave()
        await settle { clock.waitingCount == 1 }
        clock.advance(1_000_000_000)
        await settle { finishFirst != nil }
        coordinator.markDirty()
        coordinator.scheduleDebouncedSave()
        await settle { clock.waitingCount == 1 }
        // The ordinary input debounce expires while the previous save is held.
        clock.advance(1_000_000_000)
        await settle { clock.nextDeadline == 6_000_000_000 }
        finishFirst?.resume()
        await settle { coordinator.lastSavedRevision == 1 }
        clock.advance(3_990_000_000)
        await Task.yield()
        #expect(saved == 1)
        clock.advance(10_000_000)
        await settle { saved == 2 }
        #expect(await coordinator.saveNow())
    }

    @Test(arguments: [false, true])
    func immediateFlushDrainsInFlightEdits(exclusive: Bool) async {
        let clock = SaveDebounceClock()
        var saved = 0
        var finishFirst: CheckedContinuation<Void, Never>?
        let coordinator = V2DocumentSaveCoordinator(
            timing: FuminiwaTiming(), debounceSleep: { try await clock.sleep($0) },
            currentDocument: { NovelDocument.newDocument() }, saveOperation: { _ in
                saved += 1
                if saved == 1 {
                    await withCheckedContinuation { finishFirst = $0 }
                }
            }
        )
        coordinator.markDirty()
        coordinator.scheduleDebouncedSave()
        await settle { clock.waitingCount == 1 }
        clock.advance(2_000_000_000)
        await settle { finishFirst != nil }
        coordinator.markDirty()
        coordinator.scheduleDebouncedSave()
        let flush = Task { @MainActor in
            if exclusive {
                let result = await coordinator.performExclusiveAfterFlushing(flushAfter: true) {
                    coordinator.markDirty()
                    return true
                }
                if case let .completed(value, savedAfter) = result {
                    return value && savedAfter
                }
                return false
            }
            return await coordinator.saveNow()
        }
        // Let the immediate caller join the in-flight save before it completes.
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        finishFirst?.resume()
        #expect(await flush.value)
        #expect(saved == (exclusive ? 3 : 2))
        #expect(coordinator.lastSavedRevision == (exclusive ? 3 : 2))
        #expect(clock.now == 2_000_000_000)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0 ..< 20000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("save did not settle")
    }
}

@MainActor
private final class SaveDebounceClock {
    private struct Sleeper {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var sleepers: [UUID: Sleeper] = [:]
    private(set) var now: UInt64 = 0
    var nextDeadline: UInt64? {
        sleepers.values.map(\.deadline).min()
    }

    var waitingCount: Int {
        sleepers.count
    }

    func advance(_ nanoseconds: UInt64) {
        now += nanoseconds
        let ready = sleepers.filter { $0.value.deadline <= now }
        for id in ready.keys {
            sleepers.removeValue(forKey: id)
        }
        ready.values.forEach { $0.continuation.resume() }
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(deadline: now + nanoseconds, continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }
}
