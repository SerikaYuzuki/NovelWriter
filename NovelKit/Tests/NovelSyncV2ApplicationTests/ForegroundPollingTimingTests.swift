import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelTiming
import Testing

@Suite("Foreground head polling timing")
struct ForegroundPollingTimingTests {
    @Test func runtimeReceivesTimingValues() async throws {
        let timing = FuminiwaTiming(promotionIdleSeconds: 8, headPollTypingSeconds: 90, sendRetryMaximumSeconds: 30)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .preview(PreviewRuntimeConfiguration()), timing: timing)
        #expect(await application.timing == timing)
    }

    @Test func typingSlowsReadsAndIdleReturnsToNormal() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        await fixture.configuration.remote.setHeadHandler { _ in nil }
        await fixture.app.recordBodyEdit(workID: fixture.workID)
        let observation = Task { await fixture.app.observeForegroundSynchronization(workID: fixture.workID) {} }
        try await leafEventually { await fixture.configuration.remote.recordedHeadReads().count == 1 && fixture.clock.waitingCount == 1 }
        for step in 1 ... 12 {
            fixture.clock.advance(10)
            try await leafEventually { fixture.clock.waitingCount == 1 }
            await fixture.app.recordBodyEdit(workID: fixture.workID)
            let reads = await fixture.configuration.remote.recordedHeadReads().count
            #expect(reads == (step == 12 ? 2 : 1))
        }
        // No more body edits. At the 60-second idle boundary, the normal
        // interval is already due: no remaining 120-second wait survives.
        fixture.clock.advance(59)
        try await leafEventually { fixture.clock.waitingCount == 1 }
        #expect(await fixture.configuration.remote.recordedHeadReads().count == 2)
        fixture.clock.advance(1)
        try await leafEventually { await fixture.configuration.remote.recordedHeadReads().count == 3 && fixture.clock.waitingCount == 1 }
        fixture.clock.advance(10)
        try await leafEventually { await fixture.configuration.remote.recordedHeadReads().count == 4 }
        observation.cancel()
        await observation.value
        await fixture.close()
    }

    @Test func failureUsesItsOwnIntervalEvenWhileTyping() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        await fixture.configuration.remote.setHeadHandler { _ in throw SyncV2Failure.offline }
        await fixture.app.recordBodyEdit(workID: fixture.workID)
        let observation = Task { await fixture.app.observeForegroundSynchronization(workID: fixture.workID) {} }
        try await leafEventually { await fixture.configuration.remote.recordedHeadReads().count == 1 && fixture.clock.waitingCount == 1 }
        fixture.clock.advance(59)
        await fixture.app.recordBodyEdit(workID: fixture.workID)
        #expect(await fixture.configuration.remote.recordedHeadReads().count == 1)
        fixture.clock.advance(1)
        try await leafEventually { await fixture.configuration.remote.recordedHeadReads().count == 2 && fixture.clock.waitingCount == 1 }
        await fixture.configuration.remote.setHeadHandler { _ in nil }
        fixture.clock.advance(60)
        try await leafEventually { await fixture.configuration.remote.recordedHeadReads().count == 3 && fixture.clock.waitingCount == 1 }
        fixture.clock.advance(10)
        try await leafEventually { await fixture.configuration.remote.recordedHeadReads().count == 4 }
        observation.cancel()
        await observation.value
        await fixture.close()
    }

    @Test("foreground return and completed episode/chapter transitions restart with an immediate read", arguments: ["foreground", "episode", "chapter"])
    func newObservationChecksImmediately(trigger _: String) async throws {
        let fixture = try await LeafRuntimeFixture.make()
        await fixture.configuration.remote.setHeadHandler { _ in nil }
        await fixture.app.recordBodyEdit(workID: fixture.workID)
        let first = Task { await fixture.app.observeForegroundSynchronization(workID: fixture.workID) {} }
        try await leafEventually { await fixture.configuration.remote.recordedHeadReads().count == 1 && fixture.clock.waitingCount == 1 }
        let next = Task { await fixture.app.observeForegroundSynchronization(workID: fixture.workID) {} }
        try await leafEventually { await fixture.configuration.remote.recordedHeadReads().count == 2 }
        await first.value
        next.cancel()
        await next.value
        #expect(await fixture.app.laneValues(\.foregroundObservation).isEmpty)
        await fixture.close()
    }

    @Test func injectedIntervalsAndDifferentWorkAreIndependent() async throws {
        let fixture = try await LeafRuntimeFixture.make(timing: FuminiwaTiming(
            headPollNormalSeconds: 4, headPollTypingSeconds: 30, headPollFailureSeconds: 15, headPollTypingWindowSeconds: 8
        ))
        let start = fixture.clock.clock.now()
        await fixture.app.recordBodyEdit(workID: fixture.workID)
        #expect(await fixture.app.foregroundPollDelay(workID: fixture.workID, since: start, failed: false) == 30)
        #expect(await fixture.app.foregroundPollDelay(workID: WorkID(UUID()), since: start, failed: false) == 4)
        #expect(await fixture.app.foregroundPollDelay(workID: fixture.workID, since: start, failed: true) == 15)
        fixture.clock.advance(8)
        #expect(await fixture.app.foregroundPollDelay(workID: fixture.workID, since: start, failed: false) == 0)
        await fixture.close()
    }
}
