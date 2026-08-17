import Foundation
import NovelSyncV2

public enum SyncV2CommandPlan: Sendable {
    case idle
    case blocked(SyncV2Failure)
    case command(SealedCommand)
    case upload(SyncV2UploadTransfer)
}

public enum SyncV2CommandFailureDisposition: Sendable {
    case requeue
    case quarantine
    case park
}

/// Owns the durable pending-intent -> sealed-command transition.
///
/// `nextCommand` must return an already-sealed command before considering an
/// unsealed intent. Sealing a pending intent and linking it to the exact
/// canonical command bytes is one local transaction. A restart must return
/// those same bytes until an exact verified receipt acknowledges that intent.
public protocol SyncV2CommandPlanner: Sendable {
    func nextCommand(workID: WorkID) async throws -> SyncV2CommandPlan
    /// Enumerates durable outbox work without requiring the work to be opened
    /// in the UI.  This is the restart/connectivity wake boundary.
    func pendingWorkIDs() async throws -> [WorkID]
    func markSending(
        _ operation: SyncV2RemoteOperation,
        workID: WorkID
    ) async throws -> SyncV2RemoteOperation
    func recordFailure(
        operation: SyncV2RemoteOperation,
        workID: WorkID,
        disposition: SyncV2CommandFailureDisposition
    ) async throws
    func acknowledgeCommand(
        _ receipt: SyncV2ReceiptReadback,
        command: SealedCommand,
        verifiedInboxID: UUID?
    ) async throws
    func acknowledgeUpload(_ completion: SyncV2UploadCompletion) async throws
}

public extension SyncV2CommandPlanner {
    func pendingWorkIDs() async throws -> [WorkID] {
        []
    }
}

/// A closed semantic client. Its production adapter performs the typed v2
/// capability/upload/register/publish or conflict/restore sequence internally;
/// the application service never builds URLs or interprets HTTP/SQL details.
public protocol SyncV2RemoteClient: Sendable {
    func execute(_ operation: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution
    func downloadRemoteOnly(workID: WorkID) async throws -> SyncV2RemoteInbox
    func catalogPage(cursor: String?, pageSize: Int) async throws -> SyncV2RemoteCatalogPage
    func remoteHead(workID: WorkID) async throws -> SyncV2RemoteHead?
    func historyPage(workID: WorkID, cursor: String?, pageSize: Int) async throws -> SyncV2RemoteHistoryPage
    func remoteConflict(workID: WorkID) async throws -> SyncV2ConflictProjection?
}

public extension SyncV2RemoteClient {
    func downloadRemoteOnly(workID: WorkID) async throws -> SyncV2RemoteInbox {
        _ = workID
        throw SyncV2ApplicationError.workNotFound
    }

    func catalogPage(cursor: String?, pageSize: Int) async throws -> SyncV2RemoteCatalogPage {
        _ = cursor; _ = pageSize
        throw SyncV2Failure.authenticationRequired
    }

    func remoteHead(workID: WorkID) async throws -> SyncV2RemoteHead? {
        _ = workID
        throw SyncV2Failure.authenticationRequired
    }

    func historyPage(workID: WorkID, cursor: String?, pageSize: Int) async throws -> SyncV2RemoteHistoryPage {
        _ = workID; _ = cursor; _ = pageSize
        throw SyncV2Failure.authenticationRequired
    }

    func remoteConflict(workID: WorkID) async throws -> SyncV2ConflictProjection? {
        _ = workID
        throw SyncV2Failure.authenticationRequired
    }
}

public protocol SyncV2LocalKernel: Sendable {
    func checkpoint(_ capture: SyncV2CheckpointCapture) async throws -> SyncV2LocalCheckpoint
    func open(workID: WorkID) async throws -> SyncV2OpenedWork
    /// Retires the active account binding without rebinding the Work. The
    /// retained local bytes remain editable offline, while the old remote
    /// lane is parked and cannot be adopted by a later account.
    func parkAccountScope(
        workID: WorkID,
        binding: SyncV2AccountScopeBinding
    ) async throws
    func rebindAccountScope(
        workID: WorkID,
        from old: SyncV2AccountScopeBinding,
        to new: SyncV2AccountScopeBinding
    ) async throws
    /// Atomically retires every active Work in the supplied source scope.
    /// `from == nil` reconciles all active database bindings during cold launch.
    func transitionAccountScopes(
        from old: SyncV2AccountScopeBinding?,
        to new: SyncV2AccountScopeBinding?
    ) async throws
    /// Returns the durable active conflict projection, if one exists. This is
    /// intentionally a local read so a process restart can restore the
    /// conflict UI without a network round trip.
    func activeConflict(workID: WorkID) async throws -> SyncV2ConflictProjection?
    func localHistoryPage(
        workID: WorkID,
        cursor: String?,
        pageSize: Int
    ) async throws -> SyncV2LocalHistoryPage
    func prepareConflict(_ action: SyncV2ConflictAction) async throws -> SyncV2Preparation
    func prepareRestore(_ request: SyncV2RestoreRequest) async throws -> SyncV2Preparation
    func prepareExplicitAccountClone(
        sourceWorkID: WorkID,
        newWorkID: WorkID,
        newDocumentID: DocumentID
    ) async throws -> SyncV2ExplicitAccountClone
    func stageRemote(_ inbox: SyncV2RemoteInbox) async throws
    func verifyRemote(inboxID: UUID, workID: WorkID) async throws
    func recordConflict(
        _ conflict: SyncV2ConflictProjection,
        workID: WorkID,
        inboxID: UUID
    ) async throws
    func pendingAdoption(workID: WorkID) async throws -> SyncV2PendingAdoption?

    /// The concrete store must atomically recheck the expected current
    /// Snapshot, local generation, typed session, and absence of a newer
    /// pending intent before changing the current pointer.
    func applyStagedRemote(
        _ transaction: SyncV2AdoptionTransaction
    ) async throws -> SyncV2OpenedWork

    /// Remote-only install must be one verified transaction and fail if a
    /// local Work with this identity appeared after the download began.
    func installRemoteOnly(
        _ inbox: SyncV2RemoteInbox
    ) async throws -> SyncV2OpenedWork
}
