import NovelSyncV2

public extension SyncV2Application {
    /// Opens only the durable local state.
    ///
    /// This is the launch/editor boundary: it never consults the catalog or
    /// downloads a remote-only work. Remote-only fallback belongs exclusively
    /// to `open(workID:)`, which is an explicit remote-capable operation.
    func openLocal(workID: WorkID) async throws -> SyncV2OpenedWork {
        let opened = try await kernel.open(workID: workID)
        recordOpened(opened)
        let activeConflict = try await kernel.activeConflict(workID: workID)
        let adoption = try await kernel.pendingAdoption(workID: workID)
        if let adoption {
            setState(
                workID: workID,
                localDurability: durability(for: opened),
                remoteProgress: .readyForSafeAdoption(
                    inboxID: adoption.inboxID
                ),
                result: .adoptionPending,
                conflict: .clear
            )
        } else if let conflict = activeConflict {
            setState(
                workID: workID,
                localDurability: durability(for: opened),
                remoteProgress: .needsChoice,
                result: .conflictPending,
                conflict: .set(conflict)
            )
        }
        scheduleWorker(for: workID)
        return opened
    }

    func open(workID: WorkID) async throws -> SyncV2OpenedWork {
        do {
            return try await openLocal(workID: workID)
        } catch SyncV2ApplicationError.workNotFound {
            guard runtimeIdentity != .preview else {
                throw SyncV2ApplicationError.workNotFound
            }
            let inbox = try await libraryProvider.downloadRemoteOnly(workID: workID)
            let opened = try await kernel.installRemoteOnly(inbox)
            setState(
                workID: workID,
                localDurability: durability(for: opened),
                remoteProgress: .idle,
                result: .remoteOnlyInstalled,
                conflict: .clear
            )
            return opened
        }
    }

    func library() async throws -> SyncV2LibraryProjection {
        let projection = try await libraryProvider.library()
        return SyncV2LibraryProjection(items: projection.items.map { item in
            guard let state = states[item.workID] else { return item }
            if item.accountState == .parkedDifferentAccount {
                return SyncV2LibraryItem(
                    workID: item.workID,
                    title: item.title,
                    availability: item.availability,
                    accountState: item.accountState,
                    localGeneration: item.localGeneration,
                    remoteHead: item.remoteHead,
                    conflict: nil,
                    remoteProgress: .parkedDifferentAccount
                )
            }
            let conflict: SyncV2ConflictProjection? = switch state.remoteProgress {
            case .readyForSafeAdoption:
                nil
            default:
                state.conflict ?? item.conflict
            }
            return SyncV2LibraryItem(
                workID: item.workID,
                title: item.title,
                availability: item.availability,
                accountState: item.accountState,
                localGeneration: item.localGeneration,
                remoteHead: item.remoteHead,
                conflict: conflict,
                remoteProgress: state.remoteProgress
            )
        })
    }

    func synchronize(workID: WorkID) async throws -> SyncV2OperationResult {
        if let adoption = try await kernel.pendingAdoption(workID: workID) {
            let state = setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .readyForSafeAdoption(inboxID: adoption.inboxID),
                result: .adoptionPending,
                conflict: .clear
            )
            return SyncV2OperationResult(
                state: state,
                typedResult: .adoptionPending
            )
        }
        if let conflict = try await kernel.activeConflict(workID: workID) {
            let state = setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .needsChoice,
                result: .conflictPending,
                conflict: .set(conflict)
            )
            return SyncV2OperationResult(
                state: state,
                typedResult: .conflictPending
            )
        }
        return try await synchronizePendingCommand(workID: workID)
    }
}

private extension SyncV2Application {
    func synchronizePendingCommand(
        workID: WorkID
    ) async throws -> SyncV2OperationResult {
        let plan = try await planner.nextCommand(workID: workID)
        switch plan {
        case .idle:
            let state = setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .noChanges,
                result: .noChanges
            )
            return SyncV2OperationResult(state: state, typedResult: .noChanges)
        case let .blocked(failure):
            let state = record(failure: failure, workID: workID)
            return SyncV2OperationResult(
                state: state,
                typedResult: .failure(failure)
            )
        case .command, .upload:
            let state = setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .pending,
                result: .queued
            )
            scheduleWorker(for: workID)
            return SyncV2OperationResult(state: state, typedResult: .queued)
        }
    }
}
