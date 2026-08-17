import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

actor ProductionSyncV2Kernel: SyncV2LocalKernel, SyncV2LibraryProvider {
    private let store: LocalSyncV2Store
    private let scope: any SyncV2ScopeResolver
    private let remote: (any SyncV2RemoteClient)?

    init(store: LocalSyncV2Store, scope: any SyncV2ScopeResolver, remote: (any SyncV2RemoteClient)? = nil) {
        self.store = store
        self.scope = scope
        self.remote = remote
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

    func localHistoryPage(
        workID: WorkID,
        cursor: String?,
        pageSize: Int
    ) async throws -> SyncV2LocalHistoryPage {
        do {
            let localScope = try await scope.existingScope(workID: workID)
            let page = try await store.historyPage(
                workID: workID,
                scope: localScope,
                cursor: cursor,
                pageSize: pageSize
            )
            return SyncV2LocalHistoryPage(
                items: page.items.map {
                    SyncV2LocalHistoryOccurrence(
                        occurrenceID: $0.occurrenceID,
                        snapshotID: $0.snapshotID,
                        reason: $0.reason,
                        pinned: $0.pinned,
                        localGeneration: $0.localGeneration,
                        createdAt: $0.createdAt
                    )
                },
                nextCursor: page.nextCursor
            )
        } catch {
            throw mapStoreError(error)
        }
    }

    func prepareConflict(
        _ action: SyncV2ConflictAction
    ) async throws -> SyncV2Preparation {
        do {
            let localScope = try await scope.existingScope(workID: action.workID)
            guard case .bound = localScope,
                  let active = try await store.activeConflict(
                      workID: action.workID,
                      scope: localScope
                  ),
                  active.conflictID == action.conflictID,
                  active.revision == action.revision,
                  active.sourceGeneration == action.sourceGeneration,
                  active.localSnapshotID == action.localSnapshotID,
                  active.remoteSnapshotID == action.remoteSnapshotID else {
                throw SyncV2ApplicationError.staleConflictAction
            }
            let remoteHead = try await store.remoteHeadForConflict(
                active,
                scope: localScope
            )
            switch action.choice {
            case .useDevice:
                let prepared = try await store.prepareUseDevice(
                    V2DeviceResolutionRequest(
                        workID: action.workID,
                        conflictID: action.conflictID,
                        revision: action.revision,
                        sourceGeneration: action.sourceGeneration,
                        localSnapshotID: action.localSnapshotID,
                        remoteSnapshotID: action.remoteSnapshotID,
                        inboxID: store.conflictInboxID(active),
                        remoteHead: remoteHead
                    ),
                    scope: localScope
                )
                return SyncV2Preparation(
                    intentID: prepared.intentID,
                    noChanges: prepared.noChanges
                )
            case .useServer:
                let prepared = try await store.prepareUseServer(
                    V2ServerResolutionRequest(
                        workID: action.workID,
                        conflictID: action.conflictID,
                        revision: action.revision,
                        sourceGeneration: action.sourceGeneration,
                        localSnapshotID: action.localSnapshotID,
                        remoteSnapshotID: action.remoteSnapshotID,
                        inboxID: store.conflictInboxID(active),
                        expectedRemoteHead: remoteHead
                    ),
                    scope: localScope
                )
                return SyncV2Preparation(intentID: prepared.intentID, noChanges: prepared.noChanges)
            case .keepBoth:
                let newWorkID = action.newWorkID ?? WorkID(UUID())
                let newDocumentID = action.newDocumentID ?? DocumentID(UUID())
                let prepared = try await store.prepareKeepBothResolution(
                    V2KeepBothPreparationRequest(
                        workID: action.workID,
                        conflictID: action.conflictID,
                        revision: action.revision,
                        sourceGeneration: action.sourceGeneration,
                        localSnapshotID: action.localSnapshotID,
                        remoteSnapshotID: action.remoteSnapshotID,
                        newWorkID: newWorkID,
                        newDocumentID: newDocumentID
                    ),
                    scope: localScope
                )
                // The store transaction has already installed the clone.  A
                // local open here gives the application the exact bytes to
                // hand to the editor before it wakes the source worker.
                let clone = try await store.open(
                    workID: prepared.reservation.newWorkID,
                    scope: localScope
                )
                return SyncV2Preparation(
                    intentID: prepared.intentID,
                    noChanges: false,
                    preparedWorkID: clone.summary.workID
                )
            }
        } catch SyncV2ApplicationError.staleConflictAction {
            throw SyncV2ApplicationError.staleConflictAction
        } catch {
            throw mapStoreError(error)
        }
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

    func prepareExplicitAccountClone(
        sourceWorkID: WorkID,
        newWorkID: WorkID,
        newDocumentID: DocumentID
    ) async throws -> SyncV2ExplicitAccountClone {
        do {
            let sourceScope = try await scope.existingScope(workID: sourceWorkID)
            guard let destination = try await scope.activeBinding() else {
                throw SyncV2Failure.authenticationRequired
            }
            let prepared = try await store.prepareExplicitAccountClone(
                sourceWorkID: sourceWorkID,
                sourceScope: sourceScope,
                newWorkID: newWorkID,
                newDocumentID: newDocumentID,
                destination: destination
            )
            guard let intentID = prepared.intentID else { throw SyncV2Failure.fatal(.invalidLocalState) }
            return SyncV2ExplicitAccountClone(
                sourceWorkID: sourceWorkID,
                newWorkID: newWorkID,
                newDocumentID: newDocumentID,
                intentID: intentID
            )
        } catch { throw mapStoreError(error) }
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

    func recordConflict(
        _ conflict: SyncV2ConflictProjection,
        workID: WorkID,
        inboxID: UUID
    ) async throws {
        do {
            let localScope = try await scope.existingScope(workID: workID)
            _ = try await store.appendConflictFromVerifiedInbox(
                workID: workID,
                inboxID: inboxID,
                conflictID: conflict.conflictID,
                revision: conflict.revision,
                localSnapshotID: conflict.localSnapshotID,
                remoteSnapshotID: conflict.remoteSnapshotID,
                sourceGeneration: conflict.sourceGeneration,
                scope: localScope
            )
        } catch { throw mapStoreError(error) }
    }

    func pendingAdoption(workID: WorkID) async throws -> SyncV2PendingAdoption? {
        let localScope = try await scope.existingScope(workID: workID)
        guard let pending = try await store.pendingServerAdoption(
            workID: workID,
            scope: localScope
        ) else { return nil }
        return SyncV2PendingAdoption(
            workID: pending.workID,
            inboxID: pending.inboxID,
            expectedLocalVersion: SyncV2LocalVersion(
                generation: pending.expectedLocalGeneration,
                snapshotID: pending.expectedCurrentSnapshotID
            ),
            conflictID: pending.conflictID,
            conflictRevision: pending.conflictRevision
        )
    }

    func applyStagedRemote(
        _ transaction: SyncV2AdoptionTransaction
    ) async throws -> SyncV2OpenedWork {
        do {
            let localScope = try await scope.existingScope(workID: transaction.boundary.workID)
            let result = try await store.adoptPendingServerResolution(
                workID: transaction.boundary.workID,
                inboxID: transaction.boundary.inboxID,
                scope: localScope
            )
            return SyncV2OpenedWork(
                workID: transaction.boundary.workID,
                document: result.document,
                documentCreatedAt: result.documentCreatedAt,
                attachments: result.attachments,
                generation: result.summary.localGeneration,
                snapshotID: result.summary.currentSnapshotID
            )
        } catch { throw mapStoreError(error) }
    }

    func installRemoteOnly(
        _ inbox: SyncV2RemoteInbox
    ) async throws -> SyncV2OpenedWork {
        guard let binding = try await scope.activeBinding() else {
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
        if let binding = try await scope.activeBinding() {
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
        guard let remote else { throw SyncV2ApplicationError.workNotFound }
        return try await remote.downloadRemoteOnly(workID: workID)
    }

    func catalogPage(cursor: String?, pageSize: Int) async throws -> SyncV2RemoteCatalogPage {
        guard let remote else { throw SyncV2Failure.authenticationRequired }
        return try await remote.catalogPage(cursor: cursor, pageSize: pageSize)
    }

    func remoteHead(workID: WorkID) async throws -> SyncV2RemoteHead? {
        guard let remote else { throw SyncV2Failure.authenticationRequired }
        return try await remote.remoteHead(workID: workID)
    }

    func historyPage(workID: WorkID, cursor: String?, pageSize: Int) async throws -> SyncV2RemoteHistoryPage {
        guard let remote else { throw SyncV2Failure.authenticationRequired }
        return try await remote.historyPage(workID: workID, cursor: cursor, pageSize: pageSize)
    }

    func remoteConflict(workID: WorkID) async throws -> SyncV2ConflictProjection? {
        guard let remote else { throw SyncV2Failure.authenticationRequired }
        return try await remote.remoteConflict(workID: workID)
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
            expectedRemoteHead: V2RemoteHead(
                validatedSnapshotID: expectedRemoteHead.snapshotID,
                generation: expectedRemoteHead.generation
            )
        )
    }
}
