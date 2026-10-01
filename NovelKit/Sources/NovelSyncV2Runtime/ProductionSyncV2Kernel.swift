import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

actor ProductionSyncV2Kernel: SyncV2LocalKernel, SyncV2LibraryProvider {
    let store: LocalSyncV2Store
    let scope: any SyncV2ScopeResolver

    init(store: LocalSyncV2Store, scope: any SyncV2ScopeResolver) {
        self.store = store
        self.scope = scope
    }

    func snapshotAvailability(workID: WorkID, snapshotID: SnapshotID) async throws -> SyncV2SnapshotAvailability {
        let localScope = try await scope.existingScope(workID: workID)
        let availability = try await store.snapshotAvailability(workID: workID, snapshotID: snapshotID, scope: localScope)
        return switch availability {
        case .local: .local
        case .unfetched: .unfetched
        case .unknown: .unknown
        }
    }

    func writingContext(workID: WorkID) async throws -> SyncV2WritingContext {
        let active = try await scope.activeBinding()
        let local = try await scope.existingScope(workID: workID)
        let remoteBinding: SyncV2AccountScopeBinding? = if case let .bound(binding) = local, binding == active,
                                                           try await store.workDeletion(workID: workID) == nil,
                                                           try await store.workSummary(workID: workID, scope: local)
                                                           .acknowledgedHeadGeneration != nil {
            SyncV2AccountScopeBinding(accountID: binding.accountID, accountFence: binding.accountFence,
                                      serverInstanceID: binding.serverInstanceID, protocolEpoch: binding.protocolEpoch)
        } else {
            nil
        }
        let common = active.map { "account:\($0.serverInstanceID):\($0.accountID)" } ?? "local:common"
        return SyncV2WritingContext(workID: workID, commonNamespace: common, binding: remoteBinding,
                                    commonBinding: active.map { SyncV2AccountScopeBinding(
                                        accountID: $0.accountID,
                                        accountFence: $0.accountFence,
                                        serverInstanceID: $0.serverInstanceID,
                                        protocolEpoch: $0.protocolEpoch
                                    ) })
    }

    func localRescuableWorks() async throws -> [SyncV2ProtectedWork] {
        var values: [SyncV2ProtectedWork] = []
        for workID in try await store.workDeletionIDs() {
            guard let localScope = try? await scope.existingScope(workID: workID),
                  let source = try? await store.open(workID: workID, scope: localScope),
                  let document = source.document else { continue }
            values.append(SyncV2ProtectedWork(workID: workID, title: document.title, deletedAt: nil, localRescue: true))
        }
        return values
    }

    func rescueLocalWork(sourceWorkID: WorkID, newWorkID: WorkID, newDocumentID: DocumentID) async throws -> SyncV2OpenedWork {
        let localScope = try await scope.existingScope(workID: sourceWorkID)
        let result = try await store.rescueLocalWork(sourceWorkID: sourceWorkID, sourceScope: localScope,
                                                     newWorkID: newWorkID, newDocumentID: newDocumentID)
        return SyncV2OpenedWork(workID: newWorkID, document: result.document,
                                documentCreatedAt: result.documentCreatedAt,
                                attachments: result.attachments, resources: result.resources,
                                generation: result.summary.localGeneration, snapshotID: result.summary.currentSnapshotID)
    }

    func oldestUnreceivedChange(workID: WorkID) async throws -> Date? {
        let localScope = try await scope.existingScope(workID: workID)
        return try await store.oldestUnreceivedChange(workID: workID, scope: localScope)
    }

    func workDeletions() async throws -> [SyncV2WorkDeletion] {
        var result: [SyncV2WorkDeletion] = []
        for id in try await store.workDeletionIDs() {
            if let record = try await store.workDeletion(workID: id) {
                result.append(record.applicationValue)
            }
        }
        return result
    }

    func prepareWorkDeletion(workID: WorkID) async throws -> SyncV2WorkDeletion {
        try await store.prepareWorkDeletion(workID: workID, activeBinding: scope.activeBinding()).applicationValue
    }

    func completeWorkDeletion(_ deletion: SyncV2WorkDeletion) async throws {
        guard let record = try await store.workDeletion(workID: deletion.workID),
              record.applicationValue == deletion else { throw SyncV2ApplicationError.safeBoundaryRejected }
        // Recheck the account after the remote await; a different login cannot complete this intent.
        let activeBinding = try await scope.activeBinding()
        guard record.binding == nil || record.binding == activeBinding else { throw SyncV2Failure.accountFenceChanged }
        try await store.completeWorkDeletion(record)
    }

    func hasUnpromotedLeaf(workID: WorkID) async throws -> Bool {
        let localScope = try await scope.existingScope(workID: workID)
        return try await store.hasUnpromotedLeaf(workID: workID, scope: localScope)
    }

    func promoteCurrentLeaf(workID: WorkID) async throws -> Bool {
        let localScope = try await scope.existingScope(workID: workID)
        return try await store.promoteCurrentLeaf(workID: workID, scope: localScope)
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
                    attachments: capture.attachments,
                    resources: capture.resources
                ),
                scope: localScope
            )
            return SyncV2LocalCheckpoint(
                snapshotID: result.snapshotID,
                generation: result.generation,
                intentID: result.intentID,
                noChanges: result.noChanges,
                promotedLeaf: result.promotedLeaf
            )
        } catch {
            throw mapStoreError(error)
        }
    }

    /// Read only the generation; checkpoint still fully validates the current
    /// snapshot through scopeForCheckpoint before replacing any local pointer.
    func currentGeneration(workID: WorkID) async throws -> Int64 {
        do {
            guard try await store.workDeletion(workID: workID) == nil else { throw SyncV2ApplicationError.workDeletionPending }
            let localScope = try await scope.existingScope(workID: workID)
            return try await store.workSummary(workID: workID, scope: localScope).localGeneration
        } catch {
            throw mapStoreError(error)
        }
    }

    func currentVersion(workID: WorkID) async throws -> SyncV2LocalVersion {
        do {
            guard try await store.workDeletion(workID: workID) == nil else { throw SyncV2ApplicationError.workDeletionPending }
            let localScope = try await scope.existingScope(workID: workID)
            let summary = try await store.workSummary(workID: workID, scope: localScope)
            guard let snapshotID = summary.currentSnapshotID else { throw SyncV2ApplicationError.safeBoundaryRejected }
            return SyncV2LocalVersion(generation: summary.localGeneration, snapshotID: snapshotID)
        } catch {
            throw mapStoreError(error)
        }
    }

    func open(workID: WorkID) async throws -> SyncV2OpenedWork {
        do {
            guard try await store.workDeletion(workID: workID) == nil else { throw SyncV2ApplicationError.workDeletionPending }
            let localScope = try await scope.existingScope(workID: workID)
            let result = try await store.open(workID: workID, scope: localScope)
            return SyncV2OpenedWork(
                workID: workID,
                document: result.document,
                documentCreatedAt: result.documentCreatedAt,
                attachments: result.attachments,
                resources: result.resources,
                generation: result.summary.localGeneration,
                snapshotID: result.summary.currentSnapshotID
            )
        } catch {
            throw mapStoreError(error)
        }
    }

    func parkAccountScope(workID: WorkID, binding: SyncV2AccountScopeBinding) async throws {
        do {
            let storeBinding = V2AccountBinding(
                accountID: binding.accountID,
                accountFence: binding.accountFence,
                serverInstanceID: binding.serverInstanceID,
                protocolEpoch: binding.protocolEpoch
            )
            try await store.parkWork(workID: workID, binding: storeBinding)
        } catch {
            throw mapStoreError(error)
        }
    }

    func rebindAccountScope(
        workID: WorkID,
        from old: SyncV2AccountScopeBinding,
        to new: SyncV2AccountScopeBinding
    ) async throws {
        let oldBinding = V2AccountBinding(
            accountID: old.accountID,
            accountFence: old.accountFence,
            serverInstanceID: old.serverInstanceID,
            protocolEpoch: old.protocolEpoch
        )
        do {
            let newBinding = V2AccountBinding(
                accountID: new.accountID,
                accountFence: new.accountFence,
                serverInstanceID: new.serverInstanceID,
                protocolEpoch: new.protocolEpoch
            )
            guard oldBinding.accountID == newBinding.accountID else {
                throw SyncV2StoreError.accountMismatch
            }
            try await store.rebindWork(workID: workID, from: oldBinding, to: newBinding)
        } catch {
            throw mapStoreError(error)
        }
    }

    func transitionAccountScopes(
        from old: SyncV2AccountScopeBinding?,
        to new: SyncV2AccountScopeBinding?
    ) async throws {
        let oldBinding = old.map {
            V2AccountBinding(
                accountID: $0.accountID,
                accountFence: $0.accountFence,
                serverInstanceID: $0.serverInstanceID,
                protocolEpoch: $0.protocolEpoch
            )
        }
        let newBinding = new.map {
            V2AccountBinding(
                accountID: $0.accountID,
                accountFence: $0.accountFence,
                serverInstanceID: $0.serverInstanceID,
                protocolEpoch: $0.protocolEpoch
            )
        }
        do {
            try await store.transitionAccountScopes(from: oldBinding, to: newBinding)
        } catch {
            throw mapStoreError(error)
        }
    }

    func activeConflict(workID: WorkID) async throws -> SyncV2ConflictProjection? {
        do {
            let localScope = try await scope.existingScope(workID: workID)
            guard case .bound = localScope else { return nil }
            guard let conflict = try await store.activeConflict(
                workID: workID,
                scope: localScope
            ) else { return nil }
            return SyncV2ConflictProjection(
                conflictID: conflict.conflictID,
                revision: conflict.revision,
                baseSnapshotID: conflict.baseSnapshotID,
                localSnapshotID: conflict.localSnapshotID,
                remoteSnapshotID: conflict.remoteSnapshotID,
                sourceGeneration: conflict.sourceGeneration,
                commandID: nil
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
}

extension ProductionSyncV2Kernel {
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
                V2ConflictCandidate(
                    conflictID: conflict.conflictID, revision: conflict.revision, workID: workID,
                    baseSnapshotID: conflict.baseSnapshotID, localSnapshotID: conflict.localSnapshotID,
                    remoteSnapshotID: conflict.remoteSnapshotID, sourceGeneration: conflict.sourceGeneration
                ),
                inboxID: inboxID, scope: localScope
            )
        } catch { throw mapStoreError(error) }
    }

    func pendingAdoption(workID: WorkID) async throws -> SyncV2PendingAdoption? {
        let localScope = try await scope.existingScope(workID: workID)
        guard let pending = try await store.pendingServerAdoption(
            workID: workID,
            scope: localScope
        ) else {
            guard let update = try await store.pendingFastForward(workID: workID, scope: localScope) else { return nil }
            return SyncV2PendingAdoption(
                workID: workID, inboxID: update.inboxID,
                expectedLocalVersion: SyncV2LocalVersion(generation: update.generation, snapshotID: update.snapshotID)
            )
        }
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
            let result: V2OpenResult = if try await store.pendingServerAdoption(workID: transaction.boundary.workID, scope: localScope) != nil {
                try await store.adoptPendingServerResolution(
                    workID: transaction.boundary.workID, inboxID: transaction.boundary.inboxID, scope: localScope
                )
            } else {
                try await store.adoptPendingFastForward(
                    workID: transaction.boundary.workID, inboxID: transaction.boundary.inboxID, scope: localScope
                )
            }
            return SyncV2OpenedWork(
                workID: transaction.boundary.workID,
                document: result.document,
                documentCreatedAt: result.documentCreatedAt,
                attachments: result.attachments,
                resources: result.resources,
                generation: result.summary.localGeneration,
                snapshotID: result.summary.currentSnapshotID
            )
        } catch { throw mapStoreError(error) }
    }

    func installRemoteOnly(
        _ inbox: SyncV2RemoteInbox
    ) async throws -> SyncV2OpenedWork {
        func checkedBinding() async throws -> V2AccountBinding {
            try Task.checkCancellation()
            guard let binding = try await scope.activeBinding() else {
                throw SyncV2Failure.authenticationRequired
            }
            guard let downloaded = inbox.binding,
                  downloaded.accountId == binding.accountID,
                  downloaded.accountFence == binding.accountFence,
                  downloaded.serverInstanceId == binding.serverInstanceID,
                  downloaded.protocolEpoch == binding.protocolEpoch else {
                throw SyncV2Failure.accountFenceChanged
            }
            try Task.checkCancellation()
            return binding
        }
        do {
            ImportProgress.current?.advance(to: .checking)
            let localScope = try await V2LocalWorkScope.bound(checkedBinding())
            let prepared = try await LocalSyncV2Store.prepareInitialGraph(inbox.storeGraph)
            ImportProgress.current?.advance(to: .saving)
            _ = try await checkedBinding()
            if inbox.shallow {
                try await store.installShallowHead(prepared, scope: localScope)
            } else {
                try await store.installInitialGraph(prepared, scope: localScope)
            }
            _ = try await checkedBinding()
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
        let parked = try await parkedItems()
        let parkedIDs = Set(parked.map(\.workID))
        projectionItems = projectionItems.filter { !parkedIDs.contains($0.workID) }
        projectionItems += parked
        return SyncV2LibraryProjection(items: projectionItems)
    }
}

extension ProductionSyncV2Kernel {
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
            let remoteHead = try await store.remoteHeadForConflict(active, scope: localScope)
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
                return SyncV2Preparation(intentID: prepared.intentID, noChanges: prepared.noChanges)
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
                let clone = try await store.open(workID: prepared.reservation.newWorkID, scope: localScope)
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
}

private extension ProductionSyncV2Kernel {
    func isLocalOnly(workID: WorkID) async throws -> Bool {
        do {
            _ = try await store.open(workID: workID, scope: .unbound)
            return true
        } catch SyncV2StoreError.workNotFound {
            do {
                _ = try await store.open(workID: workID, scope: .parked)
                return true
            } catch SyncV2StoreError.workNotFound {
                return false
            }
        }
    }

    func parkedItems() async throws -> [SyncV2LibraryItem] {
        try await withThrowingTaskGroup(of: SyncV2LibraryItem.self) { group in
            for summary in try await store.listParkedWorks() {
                guard summary.currentSnapshotID != nil || summary.localGeneration != 0 else { continue }
                guard try await store.workDeletion(workID: summary.workID) == nil else { continue }
                group.addTask { [store] in
                    let opened = try await store.open(
                        workID: summary.workID,
                        scope: .parked
                    )
                    return SyncV2LibraryItem(
                        workID: summary.workID,
                        title: opened.document?.title ?? "名称未設定の作品",
                        availability: .localOnly,
                        accountState: .parkedDifferentAccount,
                        localGeneration: summary.localGeneration,
                        remoteProgress: .idle
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

    func items(
        scope localScope: V2LocalWorkScope,
        accountState: SyncV2LibraryAccountState
    ) async throws -> [SyncV2LibraryItem] {
        let summaries = try await store.listWorks(scope: localScope)
        return try await withThrowingTaskGroup(
            of: SyncV2LibraryItem.self
        ) { group in
            for summary in summaries {
                guard try await store.workDeletion(workID: summary.workID) == nil else { continue }
                group.addTask { [store] in
                    if summary.currentSnapshotID == nil, summary.localGeneration == 0 {
                        return SyncV2LibraryItem(workID: summary.workID, title: "名称未設定の作品",
                                                 availability: .remoteOnly, accountState: accountState,
                                                 localGeneration: 0, remoteProgress: .idle)
                    }
                    let opened = try await store.open(
                        workID: summary.workID,
                        scope: localScope
                    )
                    let adoption = try await store.pendingServerAdoption(
                        workID: summary.workID,
                        scope: localScope
                    )
                    let conflict = try await self.activeConflict(workID: summary.workID)
                    let pending = try await store.pendingIntents(
                        scope: localScope,
                        workID: summary.workID
                    )
                    let sealed: [V2SealedCommandRecord] = switch localScope {
                    case .bound:
                        try await store.pendingSealedCommands(
                            scope: localScope,
                            workID: summary.workID
                        )
                    case .unbound, .parked:
                        []
                    }
                    let hasLeaf = try await store.hasUnpromotedLeaf(workID: summary.workID, scope: localScope)
                    let progress: SyncV2RemoteProgress = if accountState == .parkedDifferentAccount {
                        .parkedDifferentAccount
                    } else if let adoption {
                        .readyForSafeAdoption(inboxID: adoption.inboxID)
                    } else if conflict != nil {
                        .needsChoice
                    } else if localScope == .unbound || localScope == .parked, !pending.isEmpty {
                        .authenticationRequired
                    } else if !pending.isEmpty || !sealed.isEmpty || hasLeaf {
                        .pending
                    } else {
                        .idle
                    }
                    return try await SyncV2LibraryItem(
                        workID: summary.workID,
                        title: opened.document?.title ?? "名称未設定の作品",
                        availability: .localOnly,
                        accountState: accountState,
                        localGeneration: summary.localGeneration,
                        remoteHeadConfirmed: accountState == .active && summary.acknowledgedHeadGeneration != nil,
                        conflict: adoption == nil ? conflict : nil,
                        remoteProgress: progress,
                        oldestUnreceivedAt: store.oldestUnreceivedChange(workID: summary.workID, scope: localScope),
                        historyBackfillNote: store.backfillProgressNote(workID: summary.workID)
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
        case .historyIncomplete: SyncV2Failure.retryable(.historyIncomplete)
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

private extension V2WorkDeletion {
    var applicationValue: SyncV2WorkDeletion {
        SyncV2WorkDeletion(workID: workID, binding: binding.map {
            SyncV2AccountScopeBinding(
                accountID: $0.accountID,
                accountFence: $0.accountFence,
                serverInstanceID: $0.serverInstanceID,
                protocolEpoch: $0.protocolEpoch
            )
        }, completed: completed)
    }
}
