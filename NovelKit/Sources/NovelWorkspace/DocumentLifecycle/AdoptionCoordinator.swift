import NovelSyncV2
import NovelSyncV2Application

/// D7: arm/disarm and session acquisition are platform ports, never a merged gate.
@MainActor
public struct WorkspaceAdoptionPort {
    public var isCurrent: () -> Bool
    public var session: (SyncV2PendingAdoption) async -> DocumentSessionToken
    public var arm: (DocumentSessionToken, SyncV2PendingAdoption, SyncUIState) async throws -> Void
    public var disarm: (DocumentSessionToken) async -> Void
    public var claim: (SyncV2PendingAdoption) -> Bool
    public var finishAttempt: (SyncV2PendingAdoption, Bool) -> Void
    public var install: (SyncV2OpenedWork) async -> Bool
    public var project: (SyncUIState?) -> Void

    public init(
        isCurrent: @escaping () -> Bool,
        session: @escaping (SyncV2PendingAdoption) async -> DocumentSessionToken,
        arm: @escaping (DocumentSessionToken, SyncV2PendingAdoption, SyncUIState) async throws -> Void,
        disarm: @escaping (DocumentSessionToken) async -> Void,
        claim: @escaping (SyncV2PendingAdoption) -> Bool = { _ in true },
        finishAttempt: @escaping (SyncV2PendingAdoption, Bool) -> Void = { _, _ in },
        install: @escaping (SyncV2OpenedWork) async -> Bool,
        project: @escaping (SyncUIState?) -> Void
    ) {
        self.isCurrent = isCurrent
        self.session = session
        self.arm = arm
        self.disarm = disarm
        self.claim = claim
        self.finishAttempt = finishAttempt
        self.install = install
        self.project = project
    }
}

@MainActor
public struct AdoptionCoordinator {
    public var pendingAdoption: (WorkID) async throws -> SyncV2PendingAdoption?
    public var uiState: (WorkID) async -> SyncUIState?
    public var gateToken: (DocumentSessionToken) async throws -> DocumentGateToken
    public var stateChanges: (WorkID, ContinuousClock.Instant) async -> AsyncStream<SyncV2ApplicationEvent>
    public var applyStaged: (SafeAdoptionBoundary) async throws -> SyncV2OpenedWork

    public init(application: SyncV2Application) {
        pendingAdoption = { try await application.pendingAdoption(workID: $0) }
        uiState = { await application.uiState(workID: $0) }
        gateToken = { try await application.documentGateToken(for: $0) }
        applyStaged = { try await application.applyStagedRemote(at: $0) }
        stateChanges = { await application.stateChanges(for: $0, until: $1) }
    }

    public init(
        pendingAdoption: @escaping (WorkID) async throws -> SyncV2PendingAdoption?,
        uiState: @escaping (WorkID) async -> SyncUIState?,
        gateToken: @escaping (DocumentSessionToken) async throws -> DocumentGateToken,
        applyStaged: @escaping (SafeAdoptionBoundary) async throws -> SyncV2OpenedWork,
        stateChanges: @escaping (WorkID, ContinuousClock.Instant) async -> AsyncStream<SyncV2ApplicationEvent> = { _, _ in
            AsyncStream { $0.finish() }
        }
    ) {
        self.pendingAdoption = pendingAdoption
        self.uiState = uiState
        self.gateToken = gateToken
        self.applyStaged = applyStaged
        self.stateChanges = stateChanges
    }

    /// Caller owns the prepared document boundary throughout this operation.
    /// A pending inbox never causes a new checkpoint or a network round trip.
    public func adoptAtPreparedBoundary(
        host: any WorkspaceHost, workID: WorkID, port: WorkspaceAdoptionPort
    ) async throws -> Bool {
        let context = host.operationContext
        let accepts = { !Task.isCancelled && context.isCurrent(host.operationContext) && port.isCurrent() }
        guard context.workID == workID, accepts() else { return false }
        let candidate: SyncV2PendingAdoption?
        do {
            candidate = try await pendingAdoption(workID)
        } catch {
            guard accepts() else { return false }
            throw error
        }
        guard let pending = candidate, accepts(), pending.workID == workID else { return false }
        guard let state = await uiState(workID), accepts(), state.workID == workID,
              state.lastTypedResult == .adoptionPending,
              state.remoteProgress == .readyForSafeAdoption(inboxID: pending.inboxID),
              port.claim(pending) else { return false }
        var failed = false
        defer { port.finishAttempt(pending, failed) }
        port.project(state)
        let session = await port.session(pending)
        guard accepts(), session.workID == workID else {
            await port.disarm(session)
            return false
        }
        do {
            try await port.arm(session, pending, state)
            guard accepts() else { await port.disarm(session); return false }
            let token = try await gateToken(session)
            guard accepts() else { await port.disarm(session); return false }
            let opened = try await applyStaged(SafeAdoptionBoundary(
                workID: workID, inboxID: pending.inboxID, session: session, gate: token
            ))
            guard accepts() else { await port.disarm(session); return false }
            guard opened.workID == workID, let document = opened.document,
                  context.session == nil || document.id == context.session?.documentID else { throw SyncV2ApplicationError.safeBoundaryRejected }
            await port.disarm(session)
            guard accepts(), await port.install(opened) else { return false }
            let installedContext = host.operationContext
            let adoptedState = await uiState(workID)
            guard !Task.isCancelled, installedContext.isCurrent(host.operationContext),
                  host.operationContext.workID == workID else { return false }
            port.project(adoptedState)
            return true
        } catch {
            await port.disarm(session)
            guard accepts(), !(error is CancellationError) else { return false }
            failed = true
            throw error
        }
    }

    /// Shared deadline and completion checks; platform policy decides whether to
    /// continue waiting, adopt, or refresh its shelf after a terminal projection.
    public func reproject(
        host: any WorkspaceHost, workID: WorkID,
        isCurrent: @escaping () -> Bool, receive: (SyncUIState?) async -> Bool
    ) async {
        let context = CheckpointCoordinator.context(of: host)
        let accepts = { !Task.isCancelled && CheckpointCoordinator.matches(context, host: host) && isCurrent() }
        guard context.workID == workID, accepts() else { return }
        let changes = await stateChanges(workID, .now.advanced(by: .seconds(30)))
        for await event in changes {
            guard accepts() else { return }
            guard event.concerns(workID) else { continue }
            let state = await uiState(workID)
            guard accepts() else { return }
            guard await receive(state) else { return }
        }
    }
}
