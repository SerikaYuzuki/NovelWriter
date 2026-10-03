import NovelAuth
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

protocol SyncV2ScopeResolver: Sendable {
    func activeBinding() async throws -> V2AccountBinding?
    func existingScope(workID: WorkID) async throws -> V2LocalWorkScope
    func scopeForCheckpoint(workID: WorkID) async throws -> V2LocalWorkScope
}

actor ProductionScopeResolver: SyncV2ScopeResolver {
    private let vault: (any AuthSessionVault)?
    private let store: any ProductionScopeStore
    private var checkpointContext: CheckpointScopeContext?

    init(vault: (any AuthSessionVault)?, store: any ProductionScopeStore) {
        self.vault = vault
        self.store = store
    }

    func activeBinding() async throws -> V2AccountBinding? {
        guard let vault,
              let session = try await vault.load(),
              session.syncProtocolEpoch == 2 else {
            return nil
        }
        return V2AccountBinding(
            accountID: session.accountID,
            accountFence: session.accountFence,
            serverInstanceID: session.serverInstanceID.uuidString.lowercased(),
            protocolEpoch: Int64(session.syncProtocolEpoch)
        )
    }

    func existingScope(workID: WorkID) async throws -> V2LocalWorkScope {
        let context = try await CheckpointScopeContext(workID: workID, binding: activeBinding())
        if context != checkpointContext {
            await store.invalidateCheckpointValidation()
            checkpointContext = context
        }
        if let binding = try await activeBinding() {
            do {
                _ = try await store.workSummary(
                    workID: workID,
                    scope: .bound(binding)
                )
                return .bound(binding)
            } catch SyncV2StoreError.workNotFound {
                // The unbound scope is checked below. Every other Store error
                // is evidence of unsafe local state and must remain visible.
            }
        }
        do {
            _ = try await store.workSummary(workID: workID, scope: .unbound)
            return .unbound
        } catch SyncV2StoreError.workNotFound {
            do {
                _ = try await store.workSummary(workID: workID, scope: .parked)
                return .parked
            } catch SyncV2StoreError.workNotFound {
                throw SyncV2ApplicationError.workNotFound
            }
        }
    }

    func scopeForCheckpoint(workID: WorkID) async throws -> V2LocalWorkScope {
        do {
            let localScope = try await existingScope(workID: workID)
            try await store.validateCheckpointBase(workID: workID, scope: localScope)
            return localScope
        } catch SyncV2ApplicationError.workNotFound {
            if let binding = try await activeBinding() {
                return .bound(binding)
            }
            return .unbound
        }
    }
}

protocol ProductionScopeStore: Sendable {
    func workSummary(workID: WorkID, scope: V2LocalWorkScope) async throws -> V2WorkSummary
    func validateCheckpointBase(workID: WorkID, scope: V2LocalWorkScope) async throws
    func invalidateCheckpointValidation() async

    func open(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) async throws -> V2OpenResult
}

private struct CheckpointScopeContext: Equatable {
    let workID: WorkID
    let binding: V2AccountBinding?
}

extension ProductionScopeStore {
    func validateCheckpointBase(workID: WorkID, scope: V2LocalWorkScope) async throws {
        _ = try await open(workID: workID, scope: scope)
    }

    func invalidateCheckpointValidation() async {}
}

extension LocalSyncV2Store: ProductionScopeStore {}

/// Test composition counterpart.  It deliberately accepts only the test
/// account vault and always uses the fixed fake server instance; production
/// URL/session values cannot enter a test root.
actor TestScopeResolver: SyncV2ScopeResolver {
    private let vault: TestSyncV2Vault
    private let store: any ProductionScopeStore
    private var checkpointContext: CheckpointScopeContext?

    init(vault: TestSyncV2Vault, store: any ProductionScopeStore) {
        self.vault = vault
        self.store = store
    }

    func activeBinding() async throws -> V2AccountBinding? {
        guard let account = await vault.currentAccount() else { return nil }
        return V2AccountBinding(
            accountID: account.accountID,
            accountFence: account.accountFence,
            serverInstanceID: "test-server",
            protocolEpoch: 2
        )
    }

    func existingScope(workID: WorkID) async throws -> V2LocalWorkScope {
        let context = try await CheckpointScopeContext(workID: workID, binding: activeBinding())
        if context != checkpointContext {
            await store.invalidateCheckpointValidation()
            checkpointContext = context
        }
        if let binding = try await activeBinding() {
            do {
                _ = try await store.workSummary(workID: workID, scope: .bound(binding))
                return .bound(binding)
            } catch SyncV2StoreError.workNotFound {
                // Continue to the unbound lookup.
            }
        }
        do {
            _ = try await store.workSummary(workID: workID, scope: .unbound)
            return .unbound
        } catch SyncV2StoreError.workNotFound {
            do {
                _ = try await store.workSummary(workID: workID, scope: .parked)
                return .parked
            } catch SyncV2StoreError.workNotFound {
                throw SyncV2ApplicationError.workNotFound
            }
        }
    }

    func scopeForCheckpoint(workID: WorkID) async throws -> V2LocalWorkScope {
        do {
            let localScope = try await existingScope(workID: workID)
            try await store.validateCheckpointBase(workID: workID, scope: localScope)
            return localScope
        } catch SyncV2ApplicationError.workNotFound {
            return try await activeBinding().map(V2LocalWorkScope.bound) ?? .unbound
        }
    }
}
