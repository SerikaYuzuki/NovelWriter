import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

struct WakeLifecycleTests {
    @Test func overlappingWakesShareOneScan() async throws {
        let planner = WakeTestPlanner()
        let state = InMemorySyncV2RuntimeState()
        let configuration = try TestRuntimeConfiguration()
        let app = try SyncV2Application(mode: .test(configuration), composition: SyncV2RuntimeComposition(
            identity: .test, kernel: state, planner: planner, remote: configuration.remote,
            gate: InMemorySyncV2DocumentGate(), library: state
        ))
        let first = await app.beginLifecycleWake()
        await planner.waitForScan()
        let others = await [app.beginLifecycleWake(), app.beginLifecycleWake(), app.beginLifecycleWake()]
        #expect(others.allSatisfy { $0.owner == first.owner })
        #expect(await planner.scans == 1)
        await planner.release()
        try await app.wake(reason: .networkRecovery)
        #expect(await app.lifecycleWake == nil)
    }

    @Test(arguments: [false, true])
    func cadenceAndCancellation(failure: Bool) async throws {
        let planner = WakeTestPlanner(failsCandidate: failure)
        let state = InMemorySyncV2RuntimeState()
        let configuration = try TestRuntimeConfiguration()
        let clock = LeafTestClock()
        let (delays, continuation) = AsyncStream<UInt64>.makeStream()
        let app = try SyncV2Application(mode: .test(configuration), composition: SyncV2RuntimeComposition(
            identity: .test, kernel: state, planner: planner, remote: configuration.remote,
            gate: InMemorySyncV2DocumentGate(), library: state
        ), promotionClock: clock.clock, automaticSyncSleep: { delay in
            continuation.yield(delay)
            try await Task.sleep(for: .seconds(3600))
        })
        let workID = WorkID(UUID())
        let observation = Task { await app.observeForegroundSynchronization(workID: workID) {} }
        var iterator = delays.makeAsyncIterator()
        let delay = await iterator.next()
        #expect(delay == (failure ? 60_000_000_000 : 10_000_000_000))
        observation.cancel()
        await observation.value
        #expect(await app.laneValues(\.foregroundObservation).isEmpty)
        continuation.finish()
    }
}

private actor WakeTestPlanner: SyncV2CommandPlanner {
    let failsCandidate: Bool
    var scans = 0
    private var started: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?

    init(failsCandidate: Bool = false) {
        self.failsCandidate = failsCandidate
    }

    func pendingWorkIDs() async throws -> [WorkID] {
        scans += 1
        started?.resume()
        started = nil
        await withCheckedContinuation { blocked = $0 }
        return []
    }

    func waitForScan() async {
        if scans == 0 {
            await withCheckedContinuation { started = $0 }
        }
    }

    func release() {
        blocked?.resume(); blocked = nil
    }

    func automaticSyncCandidate(workID _: WorkID) async throws -> SyncV2AutomaticSyncCandidate? {
        if failsCandidate {
            throw SyncV2Failure.offline
        }
        return nil
    }

    func requestSynchronization(workID _: WorkID) async throws {}
    func requestAutomaticSynchronization(workID _: WorkID, candidate _: SyncV2AutomaticSyncCandidate) async throws -> Bool {
        false
    }

    func nextCommand(workID _: WorkID) async throws -> SyncV2CommandPlan {
        .idle
    }

    func markSending(_ operation: SyncV2RemoteOperation, workID _: WorkID) async throws -> SyncV2RemoteOperation {
        operation
    }

    func recordFailure(operation _: SyncV2RemoteOperation, workID _: WorkID, disposition _: SyncV2CommandFailureDisposition) async throws {}
    func acknowledgeCommand(_: SyncV2ReceiptReadback, command _: SealedCommand, verifiedInboxID _: UUID?) async throws {}
    func acknowledgeUpload(_: SyncV2UploadCompletion) async throws {}
}
