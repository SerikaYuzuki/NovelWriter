import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

actor ProductionSyncV2Planner: SyncV2CommandPlanner {
    private let store: LocalSyncV2Store
    private let scope: ProductionScopeResolver

    init(store: LocalSyncV2Store, scope: ProductionScopeResolver) {
        self.store = store
        self.scope = scope
    }

    func nextCommand(workID: WorkID) async throws -> SyncV2CommandPlan {
        let localScope = try await scope.existingScope(workID: workID)
        guard case .bound = localScope else {
            let pending = try await store.pendingIntents(
                scope: localScope,
                workID: workID
            )
            return pending.isEmpty ? .idle : .blocked(.authenticationRequired)
        }
        if let record = try await store.pendingSealedCommands(
            scope: localScope,
            workID: workID
        ).first {
            return try .command(SealedCommand.decodeCanonical(record.canonicalRequest))
        }
        let pending = try await store.pendingIntents(
            scope: localScope,
            workID: workID
        )
        guard pending.isEmpty else {
            // Planning the create/object/register/publish closure requires the
            // account-scoped immutable transfer view that is not yet exposed
            // by NovelSyncV2Store. Do not manufacture a publish command.
            return .blocked(.fatal(.productionTransportIncomplete))
        }
        return .idle
    }

    func markSending(
        _ operation: SyncV2RemoteOperation,
        workID: WorkID
    ) async throws -> SyncV2RemoteOperation {
        guard case let .command(planned) = operation else {
            throw SyncV2Failure.fatal(.productionTransportIncomplete)
        }
        let localScope = try await scope.existingScope(workID: workID)
        let record = try await store.markSending(
            commandID: planned.command.commandId,
            scope: localScope
        )
        let exact = try SealedCommand.decodeCanonical(record.canonicalRequest)
        guard exact == planned.command else {
            throw SyncV2Failure.receiptMismatch
        }
        return try .command(SyncV2SealedRemoteCommand(command: exact))
    }

    func recordFailure(
        operation: SyncV2RemoteOperation,
        workID: WorkID,
        disposition: SyncV2CommandFailureDisposition
    ) async throws {
        guard case let .command(planned) = operation else { return }
        let localScope = try await scope.existingScope(workID: workID)
        switch disposition {
        case .requeue:
            try await store.requeue(
                commandID: planned.command.commandId,
                scope: localScope
            )
        case .quarantine:
            try await store.quarantine(
                commandID: planned.command.commandId,
                scope: localScope
            )
        case .park:
            try await store.park(
                commandID: planned.command.commandId,
                scope: localScope
            )
        }
    }

    func acknowledgeCommand(
        _ receipt: SyncV2ReceiptReadback,
        command: SealedCommand,
        verifiedInboxID: UUID?
    ) async throws {
        let workID = try command.workID
        let localScope = try await scope.existingScope(workID: workID)
        do {
            try await store.acknowledge(
                V2CommandAcknowledgement(
                    commandID: receipt.commandID,
                    canonicalReceiptEnvelope: receipt.canonicalResponse
                ),
                scope: localScope,
                verifiedPublishInboxID: verifiedInboxID
            )
        } catch {
            throw SyncV2Failure.receiptMismatch
        }
    }

    func acknowledgeUpload(_ completion: SyncV2UploadCompletion) async throws {
        _ = completion
        throw SyncV2Failure.fatal(.productionTransportIncomplete)
    }
}

private extension SealedCommand {
    var workID: WorkID {
        get throws {
            let object = try JSONSerialization.jsonObject(
                with: payloadBytes
            ) as? [String: Any]
            let raw = object?["workId"] as? String ??
                object?["sourceWorkId"] as? String
            guard let raw else { throw SyncV2Failure.receiptMismatch }
            return try WorkID(uuidString: raw)
        }
    }
}
