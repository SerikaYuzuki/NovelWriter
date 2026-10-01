import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

@Test func historyBackfillCoordinatorSerializesAndHonorsSuspension() async throws {
    let works = [WorkID(UUID()), WorkID(UUID())]
    let remote = BackfillCoordinatorRemote(works: works)
    let app = try applicationTestApp(state: InMemorySyncV2RuntimeState(), remote: remote)
    await app.setHistoryBackfillConstrained(true)
    try await app.resumePending()
    #expect(await remote.started.isEmpty)
    await app.setHistoryBackfillConstrained(false)
    try await eventually { await remote.started.count == 1 }
    try await app.resumePending()
    #expect(await remote.maximumActive == 1)
    let token = await app.beginAccountTransitionRemoteSuspension()
    try await eventually { await remote.active == 0 }
    #expect(await remote.cancelled == 1)
    try await app.resumePending()
    #expect(await remote.started.count == 1)
    _ = await app.endAccountTransitionRemoteSuspension(token, resume: true)
    try await eventually { await remote.started.count == 2 }
    await remote.finish()
    try await eventually { await remote.started.count >= 3 }
    #expect(await remote.maximumActive == 1)
    _ = await app.beginAccountTransitionRemoteSuspension()
}

@Test func priorityHistoryPreemptsAndPreservesOtherWork() async throws {
    let works = [WorkID(UUID()), WorkID(UUID()), WorkID(UUID())]
    let remote = BackfillCoordinatorRemote(works: works)
    let app = try applicationTestApp(state: InMemorySyncV2RuntimeState(), remote: remote)
    try await app.resumePending()
    try await eventually { await remote.started == [works[0]] }
    await app.prioritizeHistory(workID: works[2])
    try await eventually { await remote.started == [works[0], works[2]] }
    #expect(await remote.maximumActive == 1)
    await remote.finish()
    try await eventually { await remote.started.count == 3 }
    #expect(await remote.started == [works[0], works[2], works[1]])
    await remote.finish()
    try await eventually { await remote.started.count == 4 }
    #expect(await remote.started == [works[0], works[2], works[1], works[0]])
    _ = await app.beginAccountTransitionRemoteSuspension()
}

private actor BackfillCoordinatorRemote: SyncV2RemoteClient {
    let works: [WorkID]
    var started: [WorkID] = []
    var active = 0
    var maximumActive = 0
    var cancelled = 0
    var finished = Set<WorkID>()
    private var finishCurrent = false

    init(works: [WorkID]) {
        self.works = works
    }

    func backfillWorkIDs() async throws -> [WorkID] {
        works.filter { !finished.contains($0) }
    }

    func finish() {
        finishCurrent = true
    }

    func backfillHistory(workID: WorkID, progress: @escaping @Sendable () async -> Void) async throws {
        guard !finished.contains(workID) else { return }
        started.append(workID)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        do {
            while !finishCurrent {
                try await Task.sleep(for: .milliseconds(5))
            }
            finishCurrent = false
            finished.insert(workID)
            await progress()
        } catch {
            cancelled += 1
            throw error
        }
    }

    func execute(_: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution {
        throw SyncV2Failure.offline
    }
}
