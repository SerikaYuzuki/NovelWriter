import Foundation
import NovelCore
import NovelSyncV2

/// A deterministic, process-local kernel useful for previews and focused
/// application tests. It deliberately has no filesystem or network access.
public actor InMemorySyncV2Kernel: SyncV2LocalKernel {
    private struct Work: Sendable {
        var document: NovelDocument?
        var generation: Int64
        var snapshotID: SnapshotID?
        var encoded: [SnapshotID: EncodedSnapshot]
        var commands: [SealedCommand]
    }

    private var works: [WorkID: Work] = [:]

    public init() {}

    public func checkpoint(_ capture: SyncV2CheckpointCapture) async throws -> SyncV2LocalCheckpoint {
        var work = works[capture.workID] ?? Work(
            document: nil,
            generation: 0,
            snapshotID: nil,
            encoded: [:],
            commands: []
        )
        if work.snapshotID == capture.encoded.snapshotId,
           work.document == (try? SnapshotCodec.decode(
               manifestBytes: capture.encoded.manifestBytes,
               objects: capture.encoded.objects
           ))?.document {
            works[capture.workID] = work
            return SyncV2LocalCheckpoint(
                snapshotID: capture.encoded.snapshotId,
                generation: work.generation,
                intentID: nil,
                noChanges: true
            )
        }
        let model = try SnapshotCodec.decode(
            manifestBytes: capture.encoded.manifestBytes,
            objects: capture.encoded.objects
        )
        work.document = model.document
        work.generation += 1
        work.snapshotID = capture.encoded.snapshotId
        work.encoded[capture.encoded.snapshotId] = capture.encoded
        works[capture.workID] = work
        return SyncV2LocalCheckpoint(
            snapshotID: capture.encoded.snapshotId,
            generation: work.generation,
            intentID: UUID(),
            noChanges: false
        )
    }

    public func open(workID: WorkID) async throws -> SyncV2OpenedWork {
        guard let work = works[workID] else { throw SyncV2ApplicationError.workNotFound }
        return SyncV2OpenedWork(
            workID: workID,
            document: work.document,
            generation: work.generation,
            snapshotID: work.snapshotID
        )
    }

    public func pendingCommands(workID: WorkID) async throws -> [SealedCommand] {
        works[workID]?.commands ?? []
    }

    public func markSending(commandID: UUID, workID: WorkID) async throws -> SealedCommand {
        guard let command = works[workID]?.commands.first(where: { $0.commandId == commandID }) else {
            throw SyncV2ApplicationError.workNotFound
        }
        return command
    }

    public func requeue(commandID: UUID, workID: WorkID) async throws {
        _ = commandID
        _ = workID
    }

    public func acknowledge(
        _ receipt: SyncV2ReceiptReadback,
        command: SealedCommand,
        verifiedInboxID: UUID?
    ) async throws {
        _ = verifiedInboxID
        guard receipt.commandID == command.commandId,
              receipt.requestDigest == command.requestDigest,
              receipt.predicates.allVerified else {
            throw SyncV2ApplicationError.receiptMismatch
        }
        guard let workID = works.first(where: { $0.value.commands.contains { $0.commandId == command.commandId } })?.key,
              var work = works[workID] else {
            throw SyncV2ApplicationError.workNotFound
        }
        work.commands.removeAll { $0.commandId == command.commandId }
        works[workID] = work
    }

    public func prepareConflict(_ action: SyncV2ConflictAction) async throws -> SealedCommand {
        _ = action
        throw SyncV2ApplicationError.staleConflictAction
    }

    public func prepareRestore(_ request: SyncV2RestoreRequest) async throws -> SealedCommand? {
        _ = request
        return nil
    }

    public func stageRemote(_ inbox: SyncV2RemoteInbox) async throws {
        _ = inbox
    }

    public func verifyRemote(inboxID: UUID, workID: WorkID) async throws {
        _ = inboxID
        _ = workID
    }

    public func applyStagedRemote(_ boundary: SafeAdoptionBoundary) async throws -> SyncV2OpenedWork {
        try await open(workID: boundary.workID)
    }
}
