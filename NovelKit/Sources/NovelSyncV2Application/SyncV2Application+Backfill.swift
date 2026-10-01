import Foundation
import NovelSyncV2

extension SyncV2Application {
    /// Connectivity owners call this for Low Data Mode / constrained paths.
    public func setHistoryBackfillConstrained(_ constrained: Bool) async {
        backfillConstrained = constrained
        if constrained {
            backfillTask?.cancel()
        } else {
            try? await resumeHistoryBackfills()
        }
    }

    func resumeHistoryBackfills() async throws {
        for workID in try await remote.backfillWorkIDs() {
            scheduleHistoryBackfill(workID: workID)
        }
    }

    func scheduleHistoryBackfill(workID: WorkID) {
        if !backfillQueue.contains(workID) {
            backfillQueue.append(workID)
        }
        startHistoryBackfill()
    }

    private func startHistoryBackfill() {
        guard backfillTask == nil, !backfillConstrained, remoteSchedulingSuspensions.isEmpty,
              runtimeIdentity != .preview, !backfillQueue.isEmpty else { return }
        backfillTask = Task {
            defer {
                backfillTask = nil
                startHistoryBackfill()
            }
            // A single global lane, hence at most one task per WorkID. A failed
            // work cannot starve later works. Failed validation never auto-retries.
            while !Task.isCancelled, !backfillConstrained, remoteSchedulingSuspensions.isEmpty,
                  !backfillQueue.isEmpty {
                let workID = backfillQueue.removeFirst()
                let generation = historyScopeGeneration
                do {
                    try await remote.backfillHistory(workID: workID) { [weak self] in
                        await self?.backfillDidChange(generation: generation)
                    }
                } catch { recordSyncDiagnostic(workID: workID, stage: "history-backfill", error: error) }
            }
        }
    }

    private func backfillDidChange(generation: UInt64) {
        guard generation == historyScopeGeneration, remoteSchedulingSuspensions.isEmpty else { return }
        for continuation in stateChangeContinuations.values {
            continuation.yield(())
        }
    }
    // Step 3: route restore/deep-Inbox priority requests through this same lane.
}
