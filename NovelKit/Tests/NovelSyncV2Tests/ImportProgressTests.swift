import Foundation
@testable import NovelSyncV2
import Testing

struct ImportProgressTests {
    @Test("byte progress is monotonic, capped at ten updates per second, and phase changes flush")
    func throttlingAndPhases() async {
        let clock = ProgressClock()
        let progress = ImportProgress(now: { clock.now }, bufferingPolicy: .unbounded)
        progress.advance(total: 10000)
        for _ in 0 ..< 1000 {
            clock.advance(.milliseconds(1))
            progress.advance(bytes: 1)
        }
        progress.advance(bytes: -100)
        progress.advance(to: .checking)
        progress.advance(to: .saving)
        progress.advance(to: .receiving, bytes: 500)
        progress.advance(to: .opening)
        progress.finish()
        progress.advance(bytes: 500)
        var values: [ImportPhase] = []
        for await phase in progress.updates {
            values.append(phase)
        }
        #expect(values.count == 15) // initial + ten byte updates + three boundaries + final flush
        for (previous, next) in zip(values, values.dropFirst()) {
            #expect(next.stage.rawValue >= previous.stage.rawValue)
            #expect(next.receivedBytes >= previous.receivedBytes)
        }
        #expect(values.last?.stage == .opening)
        #expect(values.last?.receivedBytes == 1000)
        #expect(values.last?.fraction == 0.1)
    }

    @Test("wire activity extends only the stall timer and does not inflate raw byte progress")
    func wireAndPayloadBytesAreSeparate() {
        let clock = ProgressClock()
        let progress = ImportProgress(now: { clock.now }, bufferingPolicy: .unbounded)
        clock.advance(.seconds(10))
        #expect(progress.remaining(untilStalledFor: .seconds(60)) == .seconds(50))
        progress.received()
        #expect(progress.remaining(untilStalledFor: .seconds(60)) == .seconds(60))
        #expect(progress.value.receivedBytes == 0)
        #expect(progress.value.fraction == nil)
        progress.finish()
    }
}

private final class ProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.advanced(by: duration)
    }
}

extension ImportProgressTests {
    @Test("large object retry and final verification never count payload bytes twice")
    func objectRetryHighWater() {
        let progress = ImportProgress()
        let id = ObjectID(data: Data("object".utf8))
        progress.advance(total: 100)
        progress.receivedObject(id, bytes: 40)
        progress.receivedObject(id, bytes: 20)
        #expect(progress.value.receivedBytes == 40)
        progress.receivedObject(id, bytes: 100)
        progress.receivedObject(id, bytes: 100)
        #expect(progress.value.receivedBytes == 100)
        #expect(progress.value.fraction == 1)
        progress.finish()
        progress.receivedObject(id, bytes: 200)
        #expect(progress.value.receivedBytes == 100)
    }
}
