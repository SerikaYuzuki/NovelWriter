import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

actor ProductionSyncV2Kernel: SyncV2LocalKernel, SyncV2LibraryProvider {
    private let store: LocalSyncV2Store
    private let scope: ProductionScopeResolver

    init(store: LocalSyncV2Store, scope: ProductionScopeResolver) {
        self.store = store
        self.scope = scope
    }

    func checkpoint(
        _ capture: SyncV2CheckpointCapture
    ) async throws -> SyncV2LocalCheckpoint {
        let localScope = try await scope.scopeForCheckpoint(workID: capture.workID)
        do {
            let result = try await store.checkpoint(
                V2CheckpointRequest(
                    workID: capture.workID,
                    document: capture.document,
                    documentCreatedAt: capture.documentCreatedAt,
                    expectedGeneration: capture.expectedGeneration,
                    reason: V2CheckpointReason(rawValue: capture.reason.rawValue) ?? .autosave,
                    attachments: capture.attachments
                ),
                scope: localScope
            )
            return SyncV2LocalCheckpoint(
                snapshotID: result.snapshotID,
                generation: result.generation,
                intentID: result.intentID,
                noChanges: result.noChanges
            )
        } catch {
            throw mapStoreError(error)
        }
    }

    func open(workID: WorkID) async throws -> SyncV2OpenedWork {
        do {
            let localScope = try await scope.existingScope(workID: workID)
            let result = try await store.open(workID: workID, scope: localScope)
            return SyncV2OpenedWork(
                workID: workID,
                document: result.document,
                documentCreatedAt: result.documentCreatedAt,
                attachments: result.attachments,
                generation: result.summary.localGeneration,
                snapshotID: result.summary.currentSnapshotID
            )
        } catch {
            throw mapStoreError(error)
        }
    }

    func prepareConflict(
        _ action: SyncV2ConflictAction
    ) async throws -> SyncV2Preparation {
        _ = action
        throw SyncV2ApplicationError.productionRuntimeIncomplete
    }

    func prepareRestore(
        _ request: SyncV2RestoreRequest
    ) async throws -> SyncV2Preparation {
        do {
            let localScope = try await scope.existingScope(workID: request.workID)
            let opened = try await store.open(
                workID: request.workID,
                scope: localScope
            )
            let prepared = try await store.prepareRestore(
                V2RestorePreparationRequest(
                    workID: request.workID,
                    selectedSnapshotID: request.snapshotID,
                    expectedLocalGeneration: opened.summary.localGeneration
                ),
                scope: localScope
            )
            return SyncV2Preparation(
                intentID: prepared.checkpoint.intentID,
                noChanges: prepared.checkpoint.noChanges
            )
        } catch {
            throw mapStoreError(error)
        }
    }

    func stageRemote(_ inbox: SyncV2RemoteInbox) async throws {
        do {
            let localScope = try await scope.existingScope(workID: inbox.workID)
            try await store.stageRemoteGraph(inbox.storeGraph, scope: localScope)
        } catch {
            throw mapStoreError(error)
        }
    }

    func verifyRemote(inboxID: UUID, workID: WorkID) async throws {
        do {
            let localScope = try await scope.existingScope(workID: workID)
            try await store.verifyInbox(inboxID: inboxID, scope: localScope)
        } catch {
            throw mapStoreError(error)
        }
    }

    func pendingAdoption(workID: WorkID) async throws -> SyncV2PendingAdoption? {
        _ = workID
        // The Store currently finalizes resolveServer immediately. Until its
        // durable ready-for-safe-adoption row lands, production remote
        // execution remains fail-closed and cannot reach this path.
        return nil
    }

    func applyStagedRemote(
        _ transaction: SyncV2AdoptionTransaction
    ) async throws -> SyncV2OpenedWork {
        _ = transaction
        throw SyncV2ApplicationError.productionRuntimeIncomplete
    }

    func installRemoteOnly(
        _ inbox: SyncV2RemoteInbox
    ) async throws -> SyncV2OpenedWork {
        guard let binding = await scope.activeBinding() else {
            throw SyncV2Failure.authenticationRequired
        }
        do {
            let localScope = V2LocalWorkScope.bound(binding)
            try await store.stageRemoteGraph(inbox.storeGraph, scope: localScope)
            try await store.verifyInbox(inboxID: inbox.inboxID, scope: localScope)
            try await store.adoptInbox(inboxID: inbox.inboxID, scope: localScope)
            let opened = try await store.open(workID: inbox.workID, scope: localScope)
            return SyncV2OpenedWork(
                workID: inbox.workID,
                document: opened.document,
                documentCreatedAt: opened.documentCreatedAt,
                attachments: opened.attachments,
                generation: opened.summary.localGeneration,
                snapshotID: opened.summary.currentSnapshotID
            )
        } catch {
            throw mapStoreError(error)
        }
    }

    func library() async throws -> SyncV2LibraryProjection {
        var projectionItems: [SyncV2LibraryItem] = []
        if let binding = await scope.activeBinding() {
            projectionItems += try await items(
                scope: .bound(binding),
                accountState: .active
            )
        }
        projectionItems += try await items(
            scope: .unbound,
            accountState: .unbound
        )
        return SyncV2LibraryProjection(items: projectionItems)
    }

    func downloadRemoteOnly(workID: WorkID) async throws -> SyncV2RemoteInbox {
        _ = workID
        throw SyncV2ApplicationError.productionRuntimeIncomplete
    }
}

private extension ProductionSyncV2Kernel {
    func items(
        scope localScope: V2LocalWorkScope,
        accountState: SyncV2LibraryAccountState
    ) async throws -> [SyncV2LibraryItem] {
        let summaries = try await store.listWorks(scope: localScope)
        return try await withThrowingTaskGroup(
            of: SyncV2LibraryItem.self
        ) { group in
            for summary in summaries {
                group.addTask { [store] in
                    let opened = try await store.open(
                        workID: summary.workID,
                        scope: localScope
                    )
                    return SyncV2LibraryItem(
                        workID: summary.workID,
                        title: opened.document?.title ?? "名称未設定の作品",
                        availability: .localOnly,
                        accountState: accountState,
                        localGeneration: summary.localGeneration,
                        remoteProgress: .pending
                    )
                }
            }
            var result: [SyncV2LibraryItem] = []
            for try await item in group {
                result.append(item)
            }
            return result
        }
    }

    func mapStoreError(_ error: Error) -> any Error {
        guard let storeError = error as? SyncV2StoreError else { return error }
        return switch storeError {
        case .workNotFound: SyncV2ApplicationError.workNotFound
        case .accountMismatch: SyncV2Failure.quarantined(.differentAccount)
        case .staleCAS, .generationMismatch:
            SyncV2ApplicationError.safeBoundaryRejected
        case .staleConflictAction: SyncV2ApplicationError.staleConflictAction
        case .invalidSnapshot, .invalidAcknowledgement:
            SyncV2Failure.quarantined(.invalidRemoteData)
        default: SyncV2Failure.fatal(.invalidLocalState)
        }
    }
}

private extension SyncV2RemoteInbox {
    var storeGraph: V2RemoteSnapshotGraph {
        V2RemoteSnapshotGraph(
            inboxID: inboxID,
            workID: workID,
            headSnapshotID: headSnapshotID,
            snapshots: snapshots,
            expectedCurrentSnapshotID: expectedCurrentSnapshotID,
            expectedLocalGeneration: expectedLocalGeneration,
            expectedRemoteHead: try? V2RemoteHead(
                snapshotID: expectedRemoteHead.snapshotID,
                generation: expectedRemoteHead.generation
            )
        )
    }
}
