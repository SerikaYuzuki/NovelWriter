import Foundation
import NovelSyncV2
import NovelSyncV2Application

/// Captured from the projection rendered by the conflict sheet, including edits.
public struct WorkspaceConflictSelection: Sendable {
    public let context: WorkspaceOperationContext
    public let conflict: SyncV2ConflictProjection

    public init(context: WorkspaceOperationContext, conflict: SyncV2ConflictProjection) {
        self.context = context
        self.conflict = conflict
    }
}

/// Retains the allocated clone identity; retries never prepare another conflict.
public struct WorkspaceKeepBothHandoff: Sendable {
    public let context: WorkspaceOperationContext
    public let action: SyncV2ConflictAction

    public init(context: WorkspaceOperationContext, action: SyncV2ConflictAction) {
        self.context = context
        self.action = action
    }
}

@MainActor
public struct WorkspaceConflictPort {
    public var isCurrent: () -> Bool
    public var isSaved: () -> Bool
    public var displayedState: () -> SyncUIState?
    public var retainHandoff: (WorkspaceKeepBothHandoff) -> Void
    public var freeze: (WorkID?) -> Void
    public var installClone: (SyncV2OpenedWork, SyncV2ConflictAction) async -> Bool
    public var project: (SyncUIState?) -> Void
    public var complete: (SyncV2ConflictChoice, SyncV2OperationResult) async -> Void

    public init(
        isCurrent: @escaping () -> Bool,
        isSaved: @escaping () -> Bool,
        displayedState: @escaping () -> SyncUIState?,
        freeze: @escaping (WorkID?) -> Void,
        retainHandoff: @escaping (WorkspaceKeepBothHandoff) -> Void = { _ in },
        installClone: @escaping (SyncV2OpenedWork, SyncV2ConflictAction) async -> Bool,
        project: @escaping (SyncUIState?) -> Void,
        complete: @escaping (SyncV2ConflictChoice, SyncV2OperationResult) async -> Void
    ) {
        self.isCurrent = isCurrent
        self.isSaved = isSaved
        self.displayedState = displayedState
        self.retainHandoff = retainHandoff
        self.freeze = freeze
        self.installClone = installClone
        self.project = project
        self.complete = complete
    }
}

@MainActor
public struct ConflictCoordinator {
    public var resolve: (WorkID, SyncV2ConflictAction) async throws -> SyncV2OperationResult
    public var restore: (WorkID, SnapshotID) async throws -> SyncV2OperationResult
    public var openLocal: (WorkID) async throws -> SyncV2OpenedWork
    public var uiState: (WorkID) async -> SyncUIState?
    public var stateChanges: (WorkID, ContinuousClock.Instant) async -> AsyncStream<SyncV2ApplicationEvent>
    public var currentSnapshotID: (WorkID) async throws -> SnapshotID?

    public init(application: SyncV2Application) {
        resolve = { try await application.resolveConflict(workID: $0, action: $1) }
        restore = { try await application.restore(workID: $0, snapshotID: $1) }
        openLocal = { try await application.openLocal(workID: $0) }
        uiState = { await application.uiState(workID: $0) }
        stateChanges = { await application.stateChanges(for: $0, until: $1) }
        currentSnapshotID = { try await application.currentSnapshotID(workID: $0) }
    }

    public init(
        resolve: @escaping (WorkID, SyncV2ConflictAction) async throws -> SyncV2OperationResult,
        restore: @escaping (WorkID, SnapshotID) async throws -> SyncV2OperationResult,
        openLocal: @escaping (WorkID) async throws -> SyncV2OpenedWork,
        uiState: @escaping (WorkID) async -> SyncUIState?,
        stateChanges: @escaping (WorkID, ContinuousClock.Instant) async -> AsyncStream<SyncV2ApplicationEvent> = { _, _ in AsyncStream { $0.finish() } },
        currentSnapshotID: @escaping (WorkID) async throws -> SnapshotID? = { _ in nil }
    ) {
        self.resolve = resolve
        self.restore = restore
        self.openLocal = openLocal
        self.uiState = uiState
        self.stateChanges = stateChanges
        self.currentSnapshotID = currentSnapshotID
    }

    /// Caller holds the OS document gate and committed IME boundary. Choosing a
    /// conflict never saves or re-reads a projection the user has not seen.
    public func resolveAtPreparedBoundary(
        host: any WorkspaceHost, selection: WorkspaceConflictSelection,
        choice: SyncV2ConflictChoice, port: WorkspaceConflictPort
    ) async throws -> Bool {
        let context = selection.context
        let accepts = { !Task.isCancelled && context.isCurrent(host.operationContext) && port.isCurrent() }
        guard let workID = context.workID, context.session?.workID == workID,
              context.editGeneration != nil, accepts(), port.isSaved(),
              let state = port.displayedState(), state.workID == workID,
              state.conflict == selection.conflict,
              case let .saved(generation, _) = state.localDurability,
              generation >= selection.conflict.sourceGeneration else { return false }
        let action = Self.action(workID: workID, conflict: selection.conflict, choice: choice)
        if let cloneID = action.newWorkID {
            port.freeze(cloneID)
            port.retainHandoff(WorkspaceKeepBothHandoff(context: context, action: action))
        }
        let result: SyncV2OperationResult
        do {
            result = try await resolve(workID, action)
        } catch {
            guard accepts(), !(error is CancellationError) else { return false }
            // A prepare may already have committed. Keep the original frozen
            // until a validated handoff rather than republish the source.
            throw error
        }
        guard accepts(), result.state.workID == workID else { return false }
        if !Self.accepts(result.typedResult) {
            port.freeze(nil)
            port.project(result.state)
            return false
        }
        if choice == .keepBoth {
            guard let opened = result.openedWork,
                  await installKeepBoth(
                      host: host, handoff: WorkspaceKeepBothHandoff(context: context, action: action), opened: opened,
                      isCurrent: port.isCurrent, install: port.installClone, project: port.project
                  ) else { return false }
            port.freeze(nil)
        } else {
            port.project(result.state)
        }
        // In particular keep-both transport resumes only after clone install.
        await port.complete(choice, result)
        return true
    }

    public static func accepts(_ result: SyncV2TypedResult) -> Bool {
        result == .queued || result == .noChanges
    }

    public static func action(workID: WorkID, conflict: SyncV2ConflictProjection, choice: SyncV2ConflictChoice) -> SyncV2ConflictAction {
        SyncV2ConflictAction(
            workID: workID, conflictID: conflict.conflictID, revision: conflict.revision,
            baseSnapshotID: conflict.baseSnapshotID, localSnapshotID: conflict.localSnapshotID,
            remoteSnapshotID: conflict.remoteSnapshotID, sourceGeneration: conflict.sourceGeneration,
            choice: choice, commandID: conflict.commandID,
            newWorkID: choice == .keepBoth ? WorkID(UUID()) : nil,
            newDocumentID: choice == .keepBoth ? DocumentID(UUID()) : nil
        )
    }

    /// Whole-work only (D3). Save inside the already prepared OS gate, preserving
    /// current text in history, then fix the post-save generation until install.
    /// EpisodeRestoreSession intentionally uses its separate edit/Undo path.
    public func restoreAtPreparedBoundary(
        host: any WorkspaceHost, workID: WorkID, snapshotID: SnapshotID,
        isCurrent: @escaping () -> Bool, save: () async -> Bool,
        install: (SyncV2OpenedWork) async -> Bool, project: (SyncUIState?) -> Void
    ) async throws -> Bool {
        let identity = CheckpointCoordinator.context(of: host)
        let acceptsIdentity = { !Task.isCancelled && CheckpointCoordinator.matches(identity, host: host) && isCurrent() }
        guard identity.workID == workID, identity.session?.workID == workID,
              acceptsIdentity(), await save(), acceptsIdentity() else { return false }
        let saved = host.operationContext
        let accepts = { acceptsIdentity() && saved.isCurrent(host.operationContext) }
        do {
            _ = try await restore(workID, snapshotID)
            guard accepts() else { return false }
            let opened = try await openLocal(workID)
            guard accepts(), opened.workID == workID, let document = opened.document,
                  document.id == saved.session?.documentID,
                  await install(opened) else { return false }
            let installed = host.operationContext
            guard !Task.isCancelled, installed.workID == workID,
                  installed.session?.workID == workID, installed.account == saved.account else { return false }
            let state = await uiState(workID)
            guard !Task.isCancelled, installed.isCurrent(host.operationContext) else { return false }
            project(state)
            return true
        } catch {
            guard accepts(), !(error is CancellationError) else { return false }
            throw error
        }
    }
}
