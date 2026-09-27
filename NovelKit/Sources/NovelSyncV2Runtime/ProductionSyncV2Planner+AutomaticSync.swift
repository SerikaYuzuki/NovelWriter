import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

extension ProductionSyncV2Planner {
    func automaticSyncCandidate(workID: WorkID) async throws -> SyncV2AutomaticSyncCandidate? {
        let localScope = try await scope.existingScope(workID: workID)
        guard case let .bound(binding) = localScope,
              let candidate = try await store.automaticSyncCandidate(workID: workID, scope: localScope) else { return nil }
        return try SyncV2AutomaticSyncCandidate(
            generation: candidate.generation,
            head: SyncV2RemoteHead(snapshotID: candidate.head.snapshotID, generation: candidate.head.generation),
            binding: SyncV2AccountScopeBinding(
                accountID: binding.accountID,
                accountFence: binding.accountFence,
                serverInstanceID: binding.serverInstanceID,
                protocolEpoch: binding.protocolEpoch
            )
        )
    }

    func requestAutomaticSynchronization(workID: WorkID, candidate: SyncV2AutomaticSyncCandidate) async throws -> Bool {
        let localScope = try await scope.existingScope(workID: workID)
        guard case let .bound(binding) = localScope,
              binding.accountID == candidate.binding.accountID,
              binding.accountFence == candidate.binding.accountFence,
              binding.serverInstanceID == candidate.binding.serverInstanceID,
              binding.protocolEpoch == candidate.binding.protocolEpoch else { return false }
        return try await store.requestAutomaticSynchronization(
            workID: workID, scope: localScope, expectedLocalGeneration: candidate.generation
        )
    }
}
