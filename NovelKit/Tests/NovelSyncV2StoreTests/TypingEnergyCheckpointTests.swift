import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import Testing

/// Opt-in wall-clock harness. Synthetic Japanese text; no remote or private DB.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_TYPING_BENCHMARK"] == "1"))
func typingEnergyCheckpointBenchmark() async throws {
    for (characters, episodes) in [(100_000, 100), (300_000, 150), (1_000_000, 300)] {
        let configuration = try TestRuntimeConfiguration()
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .createNew)
        let timing = CheckpointTimings()
        await store.observeCheckpointTiming { timing.record($0, $1) }
        let resolver = TimedCheckpointScope(store: store, timing: timing)
        let kernel = ProductionSyncV2Kernel(store: store, scope: resolver)
        let app = try SyncV2Application(mode: .test(configuration), composition: SyncV2RuntimeComposition(
            identity: .test, kernel: kernel, planner: ProductionSyncV2Planner(store: store, scope: resolver),
            remote: configuration.remote, gate: InMemorySyncV2DocumentGate(), library: kernel
        ))
        let work = WorkID(UUID())
        var document = NovelDocument(title: "合成計測", chapters: [Chapter(title: "章", episodes: (0 ..< episodes).map {
            Episode(
                title: "話\($0)",
                content: String(
                    repeating: "文",
                    count: characters / episodes + ($0 < characters % episodes ? 1 : 0)
                )
            )
        })])
        for index in 0 ..< 6 {
            if index > 0 {
                document.chapters[0].episodes[0].content += "字"
            }
            let start = ContinuousClock.now
            _ = try await app.checkpoint(
                workID: work,
                document: document,
                reason: .autosave,
                documentCreatedAt: testDate
            )
            timing.record("total", start.duration(to: .now))
            if index == 0 {
                timing.reset()
            }
        }
        print("TYPING checkpoint chars=\(characters) episodes=\(episodes) median_ms \(timing.report())")
        #expect(try await store.open(workID: work, scope: .unbound).document == document)
        await app.cancelLeafPromotion(workID: work)
        await app.cancelWorker(for: work)
        await store.close()
        try FileManager.default.removeItem(at: configuration.localRoot.url)
    }
}

private extension LocalSyncV2Store {
    func observeCheckpointTiming(_ observer: @escaping @Sendable (String, Duration) -> Void) {
        checkpointTimingObserver = observer
        executor.snapshotInsertionObserver = observer
    }
}

private actor TimedCheckpointScope: SyncV2ScopeResolver {
    let base: ProductionScopeResolver
    let timing: CheckpointTimings

    init(store: LocalSyncV2Store, timing: CheckpointTimings) {
        base = ProductionScopeResolver(vault: nil, store: store)
        self.timing = timing
    }

    func activeBinding() async throws -> V2AccountBinding? {
        try await base.activeBinding()
    }

    func existingScope(workID: WorkID) async throws -> V2LocalWorkScope {
        try await base.existingScope(workID: workID)
    }

    func scopeForCheckpoint(workID: WorkID) async throws -> V2LocalWorkScope {
        let start = ContinuousClock.now
        defer { timing.record("scope", start.duration(to: .now)) }
        return try await base.scopeForCheckpoint(workID: workID)
    }
}

private final class CheckpointTimings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [Double]] = [:]

    func record(_ phase: String, _ duration: Duration) {
        let elapsedMilliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) /
            1e15
        lock.withLock { values[phase, default: []].append(elapsedMilliseconds) }
    }

    func reset() {
        lock.withLock { values.removeAll() }
    }

    func report() -> String {
        lock.withLock {
            ["scope", "encode", "compare", "sqlite", "decode", "objectUpsert", "entryInsert", "total"].map { phase in
                let samples = values[phase, default: []].sorted()
                return "\(phase)=\(samples.isEmpty ? 0 : samples[samples.count / 2])"
            }.joined(separator: " ")
        }
    }
}
