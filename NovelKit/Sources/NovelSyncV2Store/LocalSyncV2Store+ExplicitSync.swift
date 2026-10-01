import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Reconcile the current snapshot with the server even without new edits.
    /// A fresh publish goes through the normal verified receipt/Inbox path.
    /// Existing durable commands keep their identity and retry ordering.
    func requestSynchronization(workID: WorkID, scope: V2LocalWorkScope) throws {
        guard case .bound = scope else { throw SyncV2StoreError.accountMismatch }
        try inTransaction {
            guard let row = try scopedWorkRow(workID: workID, scope: scope),
                  let generation = row[2].int64,
                  let snapshot = row[3].blob,
                  row[6].text == V2SyncLane.normal.rawValue else {
                throw SyncV2StoreError.accountMismatch
            }
            _ = try promoteCurrentLeafTransaction(workID: workID, scope: scope)
            try retryQuarantinedUploads(workID: workID, scope: scope)
            try retryInitialCreateWork(workID: workID, scope: scope)
            try retryQuarantinedPublish(workID: workID, scope: scope)
            guard try pendingIntents(scope: scope, workID: workID).isEmpty else { return }
            _ = try upsertCheckpointIntent(
                workID: workID,
                snapshotID: SnapshotID(rawValue: snapshot.hexString),
                generation: generation,
                scope: scope
            )
        }
    }
}

private extension LocalSyncV2Store {
    /// Only an explicit sync may retry an unacknowledged initial creation.
    /// Keep the first command ID and exact bytes: the server may already have
    /// committed it. Never turn a receipt failure into a fresh create command.
    func retryInitialCreateWork(workID: WorkID, scope: V2LocalWorkScope) throws {
        let records = try allSealedCommands(scope: scope, workID: workID)
        guard !records.isEmpty,
              records.allSatisfy({ $0.kind == .createWork && $0.lifecycle == .quarantined }),
              let first = records.first else { return }
        try transitionCommand(commandID: first.commandID, scope: scope, from: ["quarantined"], to: "sealed")
    }
}

private extension LocalSyncV2Store {
    /// Explicit retry preserves the original publish command and its sealed
    /// intent, including when the server committed but receipt validation failed.
    func retryQuarantinedPublish(workID: WorkID, scope: V2LocalWorkScope) throws {
        let intents = try pendingIntents(scope: scope, workID: workID)
        guard let intent = intents.first, intent.status == "sealed" else { return }
        let records = try allSealedCommands(scope: scope, workID: workID)
        guard let command = records.first(where: {
            $0.kind == .publish && $0.lifecycle == .quarantined &&
                $0.intentID == intent.intentID && $0.sourceSnapshotID == intent.sourceSnapshotID &&
                $0.sourceGeneration == intent.sourceGeneration
        }) else { return }
        try transitionCommand(commandID: command.commandID, scope: scope, from: ["quarantined"], to: "sealed")
    }
}
