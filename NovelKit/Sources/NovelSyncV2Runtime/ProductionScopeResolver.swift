import NovelAuth
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

actor ProductionScopeResolver {
    private let vault: any AuthSessionVault
    private let store: any ProductionScopeStore

    init(vault: any AuthSessionVault, store: any ProductionScopeStore) {
        self.vault = vault
        self.store = store
    }

    func activeBinding() async -> V2AccountBinding? {
        guard let session = try? await vault.load(),
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
        if let binding = await activeBinding() {
            do {
                _ = try await store.open(
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
            _ = try await store.open(workID: workID, scope: .unbound)
            return .unbound
        } catch SyncV2StoreError.workNotFound {
            throw SyncV2ApplicationError.workNotFound
        }
    }

    func scopeForCheckpoint(workID: WorkID) async throws -> V2LocalWorkScope {
        do {
            return try await existingScope(workID: workID)
        } catch SyncV2ApplicationError.workNotFound {
            if let binding = await activeBinding() {
                return .bound(binding)
            }
            return .unbound
        }
    }
}

protocol ProductionScopeStore: Sendable {
    func open(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) async throws -> V2OpenResult
}

extension LocalSyncV2Store: ProductionScopeStore {}
