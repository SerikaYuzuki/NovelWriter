import Foundation
import NovelSyncV2

public extension SyncV2Application {
    func setHistoryBackfillConstrained(_ constrained: Bool) async {
        await setHistoryBackfillNetwork(online: true, constrained: constrained)
    }

    func setHistoryBackfillNetwork(online: Bool, constrained: Bool) async {
        if !online {
            constrainedBackfills.removeAll()
        }
        backfillOnline = online
        backfillConstrained = constrained
        if !online || (constrained && activeBackfill.map { !constrainedBackfills.contains($0) } == true) {
            if let activeBackfill {
                enqueueBackfill(activeBackfill, priority: false)
            }
            backfillTask?.cancel()
        }
        notifyHistoryChange()
        if online {
            try? await resumeHistoryBackfills()
        }
    }

    func historyFetchState(workID: WorkID) async throws -> SyncV2HistoryFetchState {
        let stored = try await kernel.historyFetchState(workID: workID)
        if stored == .complete || stored == .suspended {
            return stored
        }
        if stored == .validationFailed, activeBackfill != workID || !manualBackfills.contains(workID) {
            return stored
        }
        if !backfillOnline {
            return .offline
        }
        if backfillConstrained, !constrainedBackfills.contains(workID) {
            return .constrained
        }
        if activeBackfill == workID {
            return .running
        }
        return stored == .running ? .paused : stored
    }

    /// Explicit user request; only this path may retry validation or override a costly path.
    func fetchHistoryNow(workID: WorkID, allowConstrained: Bool = false) async throws -> SyncV2HistoryFetchRequest {
        let generation = historyScopeGeneration
        let stored = try await kernel.historyFetchState(workID: workID)
        guard generation == historyScopeGeneration, remoteSchedulingSuspensions.isEmpty,
              runtimeIdentity != .preview, !deletingWorkIDs.contains(workID),
              stored != .suspended else { return .unavailable }
        guard backfillOnline else { return .offline }
        if backfillConstrained, !allowConstrained {
            return .needsNetworkConfirmation
        }
        let newlyManual = manualBackfills.insert(workID).inserted
        let newlyAllowed = allowConstrained && constrainedBackfills.insert(workID).inserted
        if activeBackfill == workID, newlyManual || newlyAllowed {
            enqueueBackfill(workID, priority: true)
            backfillTask?.cancel()
        }
        prioritizeHistory(workID: workID)
        return .queued
    }

    func historySnapshotAvailability(workID: WorkID, snapshotID: SnapshotID) async throws -> SyncV2SnapshotAvailability {
        try await kernel.snapshotAvailability(workID: workID, snapshotID: snapshotID)
    }

    internal func resumeHistoryBackfills() async throws {
        let generation = historyScopeGeneration
        let works = try await remote.backfillWorkIDs()
        guard generation == historyScopeGeneration, remoteSchedulingSuspensions.isEmpty else { return }
        for workID in works {
            scheduleHistoryBackfill(workID: workID)
        }
        startHistoryBackfill()
    }

    internal func scheduleHistoryBackfill(workID: WorkID) {
        guard activeBackfill != workID else { return }
        enqueueBackfill(workID, priority: false)
        startHistoryBackfill()
    }

    internal func prioritizeHistory(workID: WorkID) {
        guard activeBackfill != workID else { return }
        enqueueBackfill(workID, priority: true)
        if let activeBackfill {
            enqueueBackfill(activeBackfill, priority: false)
            backfillTask?.cancel()
        }
        startHistoryBackfill()
    }

    private func enqueueBackfill(_ workID: WorkID, priority: Bool) {
        guard !deletingWorkIDs.contains(workID) else { return }
        if priority {
            backfillQueue.removeAll { $0 == workID }; backfillQueue.insert(workID, at: 0)
        } else if !backfillQueue.contains(workID) {
            backfillQueue.append(workID)
        }
    }

    private func startHistoryBackfill() {
        guard backfillTask == nil, backfillOnline, remoteSchedulingSuspensions.isEmpty,
              runtimeIdentity != .preview,
              let index = backfillQueue.firstIndex(where: { !backfillConstrained || constrainedBackfills.contains($0) }) else { return }
        let workID = backfillQueue.remove(at: index)
        let generation = historyScopeGeneration
        activeBackfill = workID
        let manual = manualBackfills.contains(workID)
        let allowConstrained = constrainedBackfills.contains(workID)
        backfillTask = Task {
            defer {
                activeBackfill = nil
                backfillTask = nil
                if generation == historyScopeGeneration, !backfillQueue.contains(workID) {
                    manualBackfills.remove(workID)
                    constrainedBackfills.remove(workID)
                }
                notifyHistoryChange()
                startHistoryBackfill()
            }
            do {
                let stored = try await kernel.historyFetchState(workID: workID)
                try Task.checkCancellation()
                guard generation == historyScopeGeneration, remoteSchedulingSuspensions.isEmpty,
                      stored != .suspended, manual || stored != .validationFailed else { return }
                notifyHistoryChange()
                try await remote.backfillHistory(workID: workID, manual: manual, allowConstrained: allowConstrained) { [weak self = self] in
                    await self?.backfillDidChange(workID: workID, generation: generation)
                }
                try Task.checkCancellation()
                backfillDidChange(workID: workID, generation: generation)
            } catch {
                if !(error is CancellationError), generation == historyScopeGeneration {
                    recordSyncDiagnostic(workID: workID, stage: "history-backfill", error: error)
                }
            }
        }
    }

    private func backfillDidChange(workID: WorkID, generation: UInt64) {
        guard generation == historyScopeGeneration, remoteSchedulingSuspensions.isEmpty else { return }
        notifyHistoryChange()
        // The sealed command and Inbox are retained. Re-read the receipt through
        // the ordinary CAS/session-gated worker as each closed group arrives.
        if historyWaiting.contains(workID) {
            scheduleWorker(for: workID)
        }
    }

    internal func notifyHistoryChange() {
        for continuation in stateChangeContinuations.values {
            continuation.yield(())
        }
    }
}
