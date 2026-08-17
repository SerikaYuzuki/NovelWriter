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

/// A closed semantic client. Its production adapter performs the typed v2
/// capability/upload/register/publish or conflict/restore sequence internally;
/// the application service never builds URLs or interprets HTTP/SQL details.
public protocol SyncV2RemoteClient: Sendable {
    func execute(_ operation: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution
}

public protocol SyncV2LocalKernel: Sendable {
    func checkpoint(_ capture: SyncV2CheckpointCapture) async throws -> SyncV2LocalCheckpoint
    func open(workID: WorkID) async throws -> SyncV2OpenedWork
    func prepareConflict(_ action: SyncV2ConflictAction) async throws -> SyncV2Preparation
    func prepareRestore(_ request: SyncV2RestoreRequest) async throws -> SyncV2Preparation
    func stageRemote(_ inbox: SyncV2RemoteInbox) async throws
    func verifyRemote(inboxID: UUID, workID: WorkID) async throws
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
