import NovelSyncV2
import NovelSyncV2Application

extension ProductionSyncV2Kernel {
    func historyFetchState(workID: WorkID) async throws -> SyncV2HistoryFetchState {
        let local = try await scope.existingScope(workID: workID)
        _ = try await store.workSummary(workID: workID, scope: local)
        guard let state = try await store.backfillState(workID: workID) else { return .complete }
        guard case let .bound(binding) = local, try await binding == (scope.activeBinding()),
              try await store.workDeletion(workID: workID) == nil else { return .suspended }
        switch state.status {
        case .complete: return .complete
        case .running: return .running
        case .paused: return state.failureCode == nil ? .paused : .interrupted
        case .failed: return .validationFailed
        case .suspended: return .suspended
        }
    }
}
