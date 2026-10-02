import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

/// Opt-in wall-clock harness. Synthetic Japanese text; no remote or private DB.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_TYPING_BENCHMARK"] == "1"))
func typingEnergyCheckpointBenchmark() async throws {
    for (characters, episodes) in [(100_000, 100), (300_000, 150), (1_000_000, 300)] {
        let root = temporaryStoreRoot("typing-energy")
        let store = try LocalSyncV2Store(root: root, policy: .createNew)
        let work = WorkID(UUID())
        var document = NovelDocument(title: "合成計測", chapters: [Chapter(title: "章", episodes: (0 ..< episodes).map {
            Episode(title: "話\($0)",
                    content: String(repeating: "文", count: characters / episodes + ($0 < characters % episodes ? 1 : 0)))
        })])
        var generation: Int64 = 0
        var samples: [CheckpointTiming] = []
        var totals: [Double] = []
        for index in 0 ..< 9 {
            if index > 0 {
                document.chapters[0].episodes[0].content += "字"
            }
            let request = V2CheckpointRequest(workID: work, document: document, documentCreatedAt: testDate,
                                              expectedGeneration: generation, reason: .autosave)
            if index == 0 || index > 5 {
                let start = ContinuousClock.now
                let result = try await store.checkpoint(request, scope: .unbound)
                generation = result.generation
                if index > 0 {
                    totals.append(milliseconds(start.duration(to: .now)))
                }
            } else {
                let sample = try await store.measureChangedCheckpoint(request)
                generation = sample.result.generation
                samples.append(sample)
            }
        }
        print("TYPING checkpoint chars=\(characters) episodes=\(episodes) median_ms "
            + "encode=\(median(samples.map(\.encode))) compare=\(median(samples.map(\.compare))) "
            + "sqlite=\(median(samples.map(\.sqlite))) publicTotal=\(median(totals))")
        #expect(try await store.open(workID: work, scope: .unbound).document == document)
        await store.close()
        try FileManager.default.removeItem(at: root)
    }
}

private struct CheckpointTiming: Sendable {
    let result: V2CheckpointResult
    let encode: Double
    let compare: Double
    let sqlite: Double
}

private extension LocalSyncV2Store {
    /// Mirrors only a changed, unbound autosave's phases. Total above uses the public path.
    func measureChangedCheckpoint(_ request: V2CheckpointRequest) throws -> CheckpointTiming {
        try deletionRepository.requireNotDeleting(request.workID)
        let row = try #require(try workRepository.scopedWorkRow(workID: request.workID, scope: .unbound))
        guard row.localGeneration == request.expectedGeneration,
              row.documentID == DocumentID(request.document.id).description,
              try row.documentCreatedAt == StoreValueCoding.iso8601(request.documentCreatedAt) else {
            throw SyncV2StoreError.generationMismatch
        }
        let current = try SnapshotID(rawValue: #require(row.currentSnapshotID).hexString)
        let parents = try workRepository.checkpointParents(workID: request.workID, current: current)
        let start = ContinuousClock.now
        let model = SnapshotModel(workId: request.workID, document: request.document,
                                  documentCreatedAt: request.documentCreatedAt)
        let encoded = try SnapshotCodec.encode(model, parents: parents)
        let afterEncode = ContinuousClock.now
        let matches = try workRepository.checkpointContentMatches(workID: request.workID, current: current, candidate: encoded)
        #expect(!matches)
        let afterCompare = ContinuousClock.now
        let result = try commitCheckpointTransaction(request, scope: .unbound, createWork: false, encoded: encoded)
        return CheckpointTiming(result: result, encode: milliseconds(start.duration(to: afterEncode)),
                                compare: milliseconds(afterEncode.duration(to: afterCompare)), sqlite: milliseconds(afterCompare.duration(to: .now)))
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
}
