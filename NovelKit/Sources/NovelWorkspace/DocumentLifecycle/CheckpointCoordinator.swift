import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

/// A value capture, including candidate documents used by attachment/import boundaries.
public struct WorkspaceCheckpointRequest: Sendable {
    public let workID: WorkID
    public let document: NovelDocument
    public let reason: SyncV2CheckpointReason
    public let documentCreatedAt: Date
    public let attachments: [SyncAttachment]
    public let resources: [PortableResource]?
}

@MainActor
public struct CheckpointCoordinator {
    public enum Completion {
        case committed(SyncV2OperationResult)
        case failed
        case stale(committedLocally: Bool)
    }

    public var checkpoint: (WorkspaceCheckpointRequest) async throws -> SyncV2OperationResult
    public var uiState: (WorkID) async -> SyncUIState?
    public var synchronize: (WorkID) async throws -> SyncV2OperationResult
    public var wake: (SyncV2WakeReason) async throws -> Void

    public init(
        checkpoint: @escaping (WorkspaceCheckpointRequest) async throws -> SyncV2OperationResult,
        uiState: @escaping (WorkID) async -> SyncUIState? = { _ in nil },
        synchronize: @escaping (WorkID) async throws -> SyncV2OperationResult = { _ in throw SyncV2ApplicationError.safeBoundaryRejected },
        wake: @escaping (SyncV2WakeReason) async throws -> Void = { _ in }
    ) {
        self.checkpoint = checkpoint
        self.uiState = uiState
        self.synchronize = synchronize
        self.wake = wake
    }

    public init(application: SyncV2Application) {
        checkpoint = { request in
            try await application.checkpoint(
                workID: request.workID, document: request.document, reason: request.reason,
                documentCreatedAt: request.documentCreatedAt,
                attachments: request.attachments, resources: request.resources
            )
        }
        uiState = { await application.uiState(workID: $0) }
        synchronize = { try await application.synchronize(workID: $0) }
        wake = { try await application.wake(reason: $0) }
    }

    /// Checkpoints deliberately ignore editGeneration: edits may continue during a
    /// durable save. Work, installed session and all account fields must still match.
    public static func context(of host: any WorkspaceHost) -> WorkspaceOperationContext {
        let current = host.operationContext
        return WorkspaceOperationContext(workID: current.workID, session: current.session,
                                         account: current.account, editGeneration: nil)
    }

    public static func matches(_ context: WorkspaceOperationContext, host: any WorkspaceHost) -> Bool {
        context.isCurrent(Self.context(of: host))
    }

    /// The application commits SQLite before scheduling its worker. No extra wake,
    /// copy, or remote wait belongs to this local persistence boundary.
    public func save(
        host: any WorkspaceHost, document: NovelDocument? = nil,
        reason: SyncV2CheckpointReason, createdAt: Date,
        attachments: [SyncAttachment], resources: [PortableResource]?,
        isCurrent: () -> Bool = { true },
        applyCommitted: (SyncV2OperationResult) -> Void = { _ in },
        applyFailure: () -> Void = {}
    ) async -> Completion {
        let context = Self.context(of: host)
        guard let workID = context.workID else { return .failed }
        let request = WorkspaceCheckpointRequest(
            workID: workID, document: document ?? host.document, reason: reason,
            documentCreatedAt: createdAt, attachments: attachments, resources: resources
        )
        do {
            let result = try await checkpoint(request)
            guard Self.matches(context, host: host), isCurrent() else { return .stale(committedLocally: true) }
            // Apply in this actor turn; returning a result for the adapter to
            // apply after another await would reopen the completion race.
            applyCommitted(result)
            return .committed(result)
        } catch {
            guard Self.matches(context, host: host), isCurrent() else { return .stale(committedLocally: false) }
            applyFailure()
            return .failed
        }
    }

    public func project(
        host: any WorkspaceHost, isCurrent: () -> Bool = { true },
        apply: (SyncUIState?) -> Void
    ) async {
        let context = Self.context(of: host)
        guard let workID = context.workID else {
            if isCurrent() {
                apply(nil)
            }
            return
        }
        let state = await uiState(workID)
        guard !Task.isCancelled, Self.matches(context, host: host), isCurrent() else { return }
        apply(state)
    }

    public func observe(
        application: SyncV2Application, host: any WorkspaceHost,
        isCurrent: () -> Bool = { true },
        permitsProjection: () -> Bool = { true }, apply: (SyncUIState?) -> Void
    ) async {
        let context = Self.context(of: host)
        guard let workID = context.workID else { return }
        for await event in await application.stateChanges(for: workID) {
            guard !Task.isCancelled, Self.matches(context, host: host), isCurrent() else { return }
            guard event.concerns(workID), permitsProjection() else { continue }
            await project(host: host, isCurrent: { isCurrent() && permitsProjection() }, apply: apply)
        }
    }

    /// Platform task ownership, background time and revoke replay remain hooks.
    /// wake only schedules the durable worker; it never awaits its network receipt.
    public func resume(
        host: any WorkspaceHost, reason: SyncV2WakeReason?,
        isCurrent: () -> Bool = { true },
        beforeWake: () async -> Void = {}, afterWake: () async -> Void
    ) async {
        let context = Self.context(of: host)
        await beforeWake()
        guard !Task.isCancelled, Self.matches(context, host: host), isCurrent() else { return }
        if let reason {
            try? await wake(reason)
        }
        guard !Task.isCancelled, Self.matches(context, host: host), isCurrent() else { return }
        await afterWake()
    }
}
