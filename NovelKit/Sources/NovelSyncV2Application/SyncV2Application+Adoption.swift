import NovelSyncV2

public extension SyncV2Application {
    func beginSession(workID: WorkID) async -> DocumentSessionToken {
        let session = await gate.beginSession(workID: workID)
        sessions[workID] = session
        return session
    }

    /// Must be called while the platform DocumentOperationGate is held. The
    /// production gate adapter validates that lock context; test mode uses an
    /// isolated one-shot in-memory issuer.
    func documentGateToken(
        for session: DocumentSessionToken
    ) async throws -> DocumentGateToken {
        guard sessions[session.workID] == session,
              let state = states[session.workID],
              case let .saved(generation, snapshotID) = state.localDurability else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        return try await gate.issueToken(
            for: session,
            expectedLocalVersion: SyncV2LocalVersion(
                generation: generation,
                snapshotID: snapshotID
            )
        )
    }

    func applyStagedRemote(
        at boundary: SafeAdoptionBoundary
    ) async throws -> SyncV2OpenedWork {
        let pending = try await kernel.pendingAdoption(workID: boundary.workID)
        guard runtimeIdentity != .preview,
              pending?.inboxID == boundary.inboxID,
              pending?.expectedLocalVersion == boundary.gate.expectedLocalVersion,
              sessions[boundary.workID] == boundary.session,
              boundary.workID == boundary.session.workID,
              boundary.workID == boundary.gate.workID,
              boundary.gate.expectedLocalVersion.generation >= 0,
              await gate.validateAndConsume(
                  boundary.gate,
                  session: boundary.session
              ) else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        let opened = try await kernel.applyStagedRemote(
            SyncV2AdoptionTransaction(boundary: boundary)
        )
        setState(
            workID: boundary.workID,
            localDurability: durability(for: opened),
            remoteProgress: .idle,
            result: .sent,
            conflict: .clear
        )
        scheduleWorker(for: boundary.workID)
        return opened
    }

    func uiState(workID: WorkID) -> SyncUIState? {
        states[workID]
    }

    func pendingAdoption(
        workID: WorkID
    ) async throws -> SyncV2PendingAdoption? {
        let pending = try await kernel.pendingAdoption(workID: workID)
        guard let pending else { return nil }

        // The durable kernel acknowledgement and the in-memory UI projection
        // are separate actor hops.  A caller may observe the adoption record
        // in between those hops (especially after restart).  Project the
        // durable fact here as well so the UI never reports a stale syncing
        // state while a safe adoption is already available.
        if states[workID]?.remoteProgress != .readyForSafeAdoption(inboxID: pending.inboxID) {
            setState(
                workID: workID,
                localDurability: states[workID]?.localDurability ?? .unsaved,
                remoteProgress: .readyForSafeAdoption(inboxID: pending.inboxID),
                result: .adoptionPending
            )
        }
        return pending
    }
}
