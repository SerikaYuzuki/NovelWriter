import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelTiming
import Testing

@Suite("Automatic retry and quiet delay status")
struct RetryTests {
    @Test func configurableBackoffPreservesDefaultJitterAndCap() {
        for attempt in 0 ... 20 {
            for jitter in [0.75, 1.0, 1.25] {
                let previous = min(60, pow(2, Double(min(attempt + 1, 6))) * jitter)
                #expect(SyncV2Application.retryDelay(attempt: attempt, jitter: jitter) == previous)
            }
        }
        let timing = FuminiwaTiming(sendRetryInitialSeconds: 4, sendRetryMaximumSeconds: 20)
        #expect(SyncV2Application.retryDelay(attempt: 0, jitter: 1, timing: timing) == 4)
        #expect(SyncV2Application.retryDelay(attempt: 1, jitter: 1, timing: timing) == 8)
        #expect(SyncV2Application.retryDelay(attempt: 9, jitter: 1, timing: timing) == 20)
    }

    @Test("temporary outage recovers without another edit and uses the same operation")
    func automaticRecovery() async throws {
        let state = InMemorySyncV2RuntimeState(account: TestAccount(accountID: "account", accountFence: "fence"))
        let remote = ApplicationTestRemote([.failure(.offline), .applied()])
        let app = try applicationTestApp(state: state, remote: remote)
        let work = WorkID(UUID())
        _ = try await app.checkpoint(workID: work, document: applicationTestDocument(), reason: .explicit,
                                     documentCreatedAt: applicationTestCreatedAt)
        try await eventually(timeout: .seconds(5)) { await state.pendingIntentCount(workID: work) == 0 }
        let operations = await remote.recordedOperations()
        #expect(operations.count == 2)
        if case let .command(first) = operations[0], case let .command(retry) = operations[1] {
            #expect(first.command == retry.command)
        } else {
            Issue.record("expected a durable command retry")
        }
        #expect(await app.laneValues(\.retryTask).isEmpty)
    }

    @Test("account transition cancels a scheduled retry and authentication never schedules one")
    func retryBoundaries() async throws {
        for failure in [SyncV2Failure.offline, .authenticationRequired, .fatal(.remoteWorkDeleted)] {
            let state = InMemorySyncV2RuntimeState(account: TestAccount(accountID: "account", accountFence: "fence"))
            let remote = ApplicationTestRemote([.failure(failure)])
            let app = try applicationTestApp(state: state, remote: remote)
            let work = WorkID(UUID())
            _ = try await app.checkpoint(workID: work, document: applicationTestDocument(), reason: .explicit,
                                         documentCreatedAt: applicationTestCreatedAt)
            try await eventually { await app.laneValues(\.workerTask).isEmpty }
            #expect(await app.laneValues(\.retryTask).isEmpty == (failure != .offline))
            _ = await app.beginAccountTransitionRemoteSuspension()
            #expect(await app.laneValues(\.retryTask).isEmpty)
            #expect(await app.laneValues(\.retryOwner).isEmpty)
        }
    }

    @Test("delay threshold and a backwards clock never claim receipt")
    func delayThreshold() {
        let saved = Date(timeIntervalSince1970: 1000)
        #expect(!SyncV2DelayNotice.isDelayed(since: saved, now: saved.addingTimeInterval(299)))
        #expect(SyncV2DelayNotice.isDelayed(since: saved, now: saved.addingTimeInterval(300)))
        #expect(SyncV2DelayNotice.isDelayed(since: saved, now: saved.addingTimeInterval(-1)))
        #expect(!SyncV2DelayNotice.isDelayed(since: nil))
    }
}
