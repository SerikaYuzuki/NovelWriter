import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

actor ProductionSyncV2Planner: SyncV2CommandPlanner {
    private let store: LocalSyncV2Store
    private let scope: any SyncV2ScopeResolver
    /// Immutable object presence is reusable only in this exact account,
    /// server, protocol, fence, and Work namespace. It is separate from a
    /// command's upload capability session.
    private struct RemoteObjectPresenceKey: Hashable, Sendable {
        let binding: V2AccountBinding
        let workID: WorkID
        let objectID: ObjectID
    }

    /// Upload capabilities belong to one prepare command and one intent. A
    /// later generation may contain the same ObjectID, but must not reuse its
    /// uploadID or capability.
    private struct TransferSessionKey: Hashable, Sendable {
        let binding: V2AccountBinding
        let workID: WorkID
        let sourceGeneration: Int64
        let sourceSnapshotID: SnapshotID
        let intentID: UUID
        let objectID: ObjectID
        let commandID: UUID
    }

    private var remoteObjectPresence: Set<RemoteObjectPresenceKey> = []
    private var transfers: [TransferSessionKey: SyncV2UploadTransfer] = [:]

    init(store: LocalSyncV2Store, scope: any SyncV2ScopeResolver) {
        self.store = store
        self.scope = scope
    }

    func pendingWorkIDs() async throws -> [WorkID] {
        guard let binding = try await scope.activeBinding() else { return [] }
        return try await store.pendingWorkIDs(scope: .bound(binding))
    }

    func invalidateCaches(for workIDs: Set<WorkID>) async {
        guard !workIDs.isEmpty else { return }
        transfers = transfers.filter { !workIDs.contains($0.key.workID) }
        remoteObjectPresence = remoteObjectPresence.filter { !workIDs.contains($0.workID) }
    }

    /// The planner is a single ordered state machine; keep its branch ordering
    /// explicit so sealed command replay cannot be reordered by helpers.
    func nextCommand(workID: WorkID) async throws -> SyncV2CommandPlan {
        let localScope = try await scope.existingScope(workID: workID)
        guard case .bound = localScope else {
            await invalidateCaches(for: [workID])
            let pending = try await store.pendingIntents(scope: localScope, workID: workID)
            return pending.isEmpty ? .idle : .blocked(.authenticationRequired)
        }
        if let record = try await store.pendingSealedCommands(scope: localScope, workID: workID).first {
            return try .command(SealedCommand.decodeCanonical(record.canonicalRequest))
        }
        let pending = try await store.pendingIntents(scope: localScope, workID: workID)
        guard !pending.isEmpty else { return .idle }
        return try await planPending(workID: workID, scope: localScope, pending: pending)
    }

    private func planPending(
        workID: WorkID,
        scope localScope: V2LocalWorkScope,
        pending: [V2PendingIntent]
    ) async throws -> SyncV2CommandPlan {
        guard let view = try await store.immutableTransferView(workID: workID, scope: localScope) else {
            return .blocked(.fatal(.invalidLocalState))
        }
        let records = try await store.allSealedCommands(scope: localScope, workID: workID)
        let activeConflict = try await store.activeConflict(workID: workID, scope: localScope)
        if let intent = pending.first(where: {
            $0.kind == "conflictResolution" &&
                activeConflict?.conflictID != nil
        }),
            let active = activeConflict,
            intent.sourceSnapshotID == active.localSnapshotID,
            intent.sourceGeneration == active.sourceGeneration {
            return try await planInitialResolution(
                workID: workID,
                scope: localScope,
                view: view,
                active: active,
                intent: intent
            )
        }
        let resolutionIntent = pending.first(where: {
            $0.kind == "conflictResolution"
        })
        if activeConflict != nil, resolutionIntent == nil {
            return .idle
        }
        return try await planTransfer(
            workID: workID,
            scope: localScope,
            view: view,
            records: records,
            active: activeConflict,
            resolutionIntentID: resolutionIntent?.intentID
        )
    }

    private func planInitialResolution(
        workID: WorkID,
        scope localScope: V2LocalWorkScope,
        view: V2ImmutableTransferView,
        active: V2ConflictCandidate,
        intent: V2PendingIntent
    ) async throws -> SyncV2CommandPlan {
        let command: SealedCommand
        if let reservation = try await store.latestKeepBothReservation(
            sourceWorkID: workID,
            conflictID: active.conflictID,
            scope: localScope
        ) {
            let remoteHead = try await store.remoteHeadForConflict(active, scope: localScope)
            command = try makeClone(view, conflict: active, reservation: reservation, remoteHead: remoteHead)
        } else {
            command = try makeResolveServer(view, conflict: active)
        }
        try await store.seal(command, intentID: intent.intentID, scope: localScope)
        return .command(command)
    }

    private func planTransfer(
        workID: WorkID,
        scope localScope: V2LocalWorkScope,
        view: V2ImmutableTransferView,
        records: [V2SealedCommandRecord],
        active: V2ConflictCandidate?,
        resolutionIntentID: UUID?
    ) async throws -> SyncV2CommandPlan {
        let currentRecords = records.filter {
            $0.lifecycle == .completed &&
                $0.sourceSnapshotID == view.snapshot.snapshotId &&
                $0.sourceGeneration == view.pendingIntent.sourceGeneration
        }
        let completedKinds = Set(records.filter { $0.lifecycle == .completed }.map(\.commandKind))
        let progress = try await transferProgress(
            workID: workID,
            scope: localScope,
            view: view,
            records: currentRecords
        )
        if !completedKinds.contains("createWork"), view.summary.acknowledgedHeadGeneration == nil {
            let command = try makeCreateWork(view)
            try await store.seal(command, scope: localScope)
            return .command(command)
        }
        if let object = view.snapshot.manifest.entries.map(\.objectId).first(where: { !progress.prepared.contains($0) }) {
            let command = try makeObjectCommand(kind: "prepareObject", objectID: object, view: view)
            try await store.seal(command, scope: localScope)
            return .command(command)
        }
        if let upload = try await nextUpload(
            workID: workID,
            scope: localScope,
            view: view,
            records: currentRecords,
            progress: progress
        ) {
            return upload
        }
        let ready = progress.finalized.union(
            remoteObjectPresence
                .filter { $0.binding == view.binding && $0.workID == workID }
                .map(\.objectID)
        )
        if ready.count < progress.prepared.count {
            guard let object = progress.prepared.subtracting(ready).first else {
                return .blocked(.fatal(.invalidLocalState))
            }
            let command = try makeObjectCommand(
                kind: "finalizeObject",
                objectID: object,
                view: view,
                uploadID: currentTransfer(
                    for: object,
                    view: view,
                    records: currentRecords
                )?.uploadID
            )
            try await store.seal(command, scope: localScope)
            return .command(command)
        }
        if !progress.registered {
            let command = try makeRegister(view)
            try await store.seal(command, scope: localScope)
            return .command(command)
        }
        if let active {
            return try await planActiveTail(
                workID: workID,
                scope: localScope,
                view: view,
                active: active,
                resolutionIntentID: resolutionIntentID
            )
        }
        let command = try makePublish(view)
        try await store.seal(command, intentID: view.pendingIntent.intentID, scope: localScope)
        return .command(command)
    }

    private struct TransferProgress {
        let prepared: Set<ObjectID>
        let finalized: Set<ObjectID>
        let registered: Bool
    }

    private func transferProgress(
        workID: WorkID,
        scope localScope: V2LocalWorkScope,
        view: V2ImmutableTransferView,
        records: [V2SealedCommandRecord]
    ) async throws -> TransferProgress {
        var prepared = Set<ObjectID>()
        var finalized = Set<ObjectID>()
        var registered = false
        for record in records {
            switch record.commandKind {
            case "prepareObject":
                let object = try objectID(record)
                if let transfer = try await store.uploadTransfer(commandID: record.commandID, scope: localScope) {
                    if transfer.lifecycle == "prepared", transfer.expiresAt <= Date() {
                        continue
                    }
                    if transfer.lifecycle == "acknowledged" {
                        remoteObjectPresence.insert(
                            RemoteObjectPresenceKey(
                                binding: view.binding,
                                workID: workID,
                                objectID: transfer.objectID
                            )
                        )
                    }
                }
                prepared.insert(object)
                if let receipt = try await store.receiptReadback(commandID: record.commandID, scope: localScope),
                   receipt.result == .noChanges {
                    remoteObjectPresence.insert(
                        RemoteObjectPresenceKey(
                            binding: view.binding,
                            workID: workID,
                            objectID: object
                        )
                    )
                }
            case "finalizeObject":
                try finalized.insert(objectID(record))
            case "registerSnapshot":
                registered = try commandSnapshotID(record) == view.snapshot.snapshotId
            default:
                continue
            }
        }
        return TransferProgress(prepared: prepared, finalized: finalized, registered: registered)
    }

    private func nextUpload(
        workID: WorkID,
        scope _: V2LocalWorkScope,
        view: V2ImmutableTransferView,
        records: [V2SealedCommandRecord],
        progress: TransferProgress
    ) async throws -> SyncV2CommandPlan? {
        let candidates = view.snapshot.manifest.entries.map(\.objectId).filter {
            progress.prepared.contains($0) && !progress.finalized.contains($0) &&
                !remoteObjectPresence.contains(
                    RemoteObjectPresenceKey(
                        binding: view.binding,
                        workID: workID,
                        objectID: $0
                    )
                )
        }
        guard let target = candidates.first else { return nil }
        guard let prepare = records.reversed().first(where: {
            $0.commandKind == "prepareObject" && (try? objectID($0)) == target
        }) else {
            return nil
        }
        let sessionKey = transferSessionKey(
            for: prepare,
            objectID: target,
            view: view
        )
        if let transfer = transfers[sessionKey] {
            return .upload(transfer)
        }
        guard let transfer = try await makeTransfer(from: prepare, view: view) else {
            return nil
        }
        transfers[sessionKey] = transfer
        return .upload(transfer)
    }

    private func currentTransfer(
        for objectID: ObjectID,
        view: V2ImmutableTransferView,
        records: [V2SealedCommandRecord]
    ) -> SyncV2UploadTransfer? {
        guard let prepare = records.reversed().first(where: {
            $0.commandKind == "prepareObject" && (try? self.objectID($0)) == objectID
        }) else { return nil }
        return transfers[
            transferSessionKey(for: prepare, objectID: objectID, view: view)
        ]
    }

    private func transferSessionKey(
        for record: V2SealedCommandRecord,
        objectID: ObjectID,
        view: V2ImmutableTransferView
    ) -> TransferSessionKey {
        TransferSessionKey(
            binding: view.binding,
            workID: view.workID,
            sourceGeneration: view.pendingIntent.sourceGeneration,
            sourceSnapshotID: view.pendingIntent.sourceSnapshotID,
            intentID: view.pendingIntent.intentID,
            objectID: objectID,
            commandID: record.commandID
        )
    }

    private func planActiveTail(
        workID: WorkID,
        scope localScope: V2LocalWorkScope,
        view: V2ImmutableTransferView,
        active: V2ConflictCandidate,
        resolutionIntentID: UUID?
    ) async throws -> SyncV2CommandPlan {
        guard let resolutionIntentID,
              view.pendingIntent.intentID == resolutionIntentID else {
            return .idle
        }
        let expectedRemoteHead = try await store.remoteHeadForConflict(active, scope: localScope)
        let command: SealedCommand
        if let reservation = try await store.latestKeepBothReservation(
            sourceWorkID: workID,
            conflictID: active.conflictID,
            scope: localScope
        ) {
            guard view.summary.localGeneration >= active.sourceGeneration + 1 else {
                return .idle
            }
            command = try makeClone(
                view,
                conflict: active,
                reservation: reservation,
                remoteHead: expectedRemoteHead
            )
        } else {
            guard view.pendingIntent.sourceGeneration == active.sourceGeneration + 1,
                  view.snapshot.snapshotId != active.localSnapshotID else {
                return .idle
            }
            command = try makeResolveDevice(
                view,
                conflict: active,
                decisionSnapshotID: view.snapshot.snapshotId,
                expectedRemoteHead: expectedRemoteHead
            )
        }
        try await store.seal(command, intentID: resolutionIntentID, scope: localScope)
        return .command(command)
    }

    func markSending(
        _ operation: SyncV2RemoteOperation,
        workID: WorkID
    ) async throws -> SyncV2RemoteOperation {
        if case .upload = operation {
            return operation
        }
        guard case let .command(planned) = operation else { throw SyncV2Failure.fatal(.unsupportedCommand) }
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
        guard let entry = transfers.first(where: {
            $0.value.transferID == completion.transferID
        }) else { return }
        let key = entry.key
        let localScope = try await scope.existingScope(workID: key.workID)
        // Scope validation precedes all cache mutation. A late completion from
        // a parked/old fence may not seed the new account's object presence.
        guard case let .bound(binding) = localScope, binding == key.binding else {
            return
        }
        try await store.acknowledgeUploadTransfer(
            transferID: completion.transferID,
            byteCount: completion.acknowledgedByteCount,
            scope: localScope
        )
        remoteObjectPresence.insert(
            RemoteObjectPresenceKey(
                binding: key.binding,
                workID: key.workID,
                objectID: completion.objectID
            )
        )
    }
}

private extension ProductionSyncV2Planner {
    func makeCreateWork(_ view: V2ImmutableTransferView) throws -> SealedCommand {
        try makeCommand(kind: "createWork", payload: CreateWorkPayload(documentId: view.summary.documentID.description, workId: view.workID.description), view: view)
    }

    func makeObjectCommand(
        kind: String,
        objectID: ObjectID,
        view: V2ImmutableTransferView,
        uploadID: UUID? = nil
    ) throws -> SealedCommand {
        if kind == "prepareObject" {
            return try makeCommand(
                kind: kind,
                payload: PrepareObjectPayload(
                    byteCount: view.snapshot.objects[objectID]?.count ?? 0,
                    objectId: objectID.rawValue,
                    workId: view.workID.description
                ),
                view: view
            )
        }
        guard let uploadID else { throw SyncV2Failure.fatal(.invalidLocalState) }
        return try makeCommand(
            kind: kind,
            payload: FinalizeObjectPayload(
                byteCount: view.snapshot.objects[objectID]?.count ?? 0,
                objectId: objectID.rawValue,
                uploadId: uploadID.uuidString.lowercased(),
                workId: view.workID.description
            ),
            view: view
        )
    }

    func makeRegister(_ view: V2ImmutableTransferView) throws -> SealedCommand {
        try makeCommand(
            kind: "registerSnapshot",
            payload: RegisterSnapshotPayload(
                manifestBase64URL: view.snapshot.manifestBytes.base64URLEncodedString(),
                manifestBytesDigest: view.snapshot.snapshotId.rawValue,
                snapshotId: view.snapshot.snapshotId.rawValue,
                workId: view.workID.description
            ),
            view: view
        )
    }

    func makePublish(_ view: V2ImmutableTransferView) throws -> SealedCommand {
        let envelope = CommandEnvelope(
            binding: CommandBinding(binding: view.binding),
            commandId: UUID().uuidString.lowercased(),
            commandKind: "publish",
            payload: PublishPayload(
                candidateSnapshotId: view.snapshot.snapshotId.rawValue,
                expectedRemoteHead: view.expectedRemoteHead.map(CommandHead.init) ?? nil,
                workId: view.workID.description
            ),
            schemaVersion: 2,
            sourceGeneration: view.pendingIntent.sourceGeneration,
            sourceSnapshotId: view.pendingIntent.sourceSnapshotID.rawValue
        )
        return try SealedCommand.decodeCanonical(CanonicalJSON.encode(envelope))
    }

    func makeResolveServer(_ view: V2ImmutableTransferView, conflict: V2ConflictCandidate) throws -> SealedCommand {
        try makeCommand(
            kind: "resolveServer",
            payload: ResolveServerPayload(
                conflictId: conflict.conflictID.uuidString.lowercased(),
                conflictRevision: conflict.revision,
                expectedCurrentSnapshotId: conflict.localSnapshotID.rawValue,
                expectedLocalGeneration: conflict.sourceGeneration,
                preAdoptionSnapshotId: conflict.localSnapshotID.rawValue,
                remoteSnapshotId: conflict.remoteSnapshotID.rawValue,
                workId: view.workID.description
            ),
            view: view
        )
    }

    func makeResolveDevice(
        _ view: V2ImmutableTransferView,
        conflict: V2ConflictCandidate,
        decisionSnapshotID: SnapshotID,
        expectedRemoteHead: V2RemoteHead
    ) throws -> SealedCommand {
        let envelope = CommandEnvelope(
            binding: CommandBinding(binding: view.binding),
            commandId: UUID().uuidString.lowercased(),
            commandKind: "resolveDevice",
            payload: ResolveDevicePayload(
                conflictId: conflict.conflictID.uuidString.lowercased(),
                conflictRevision: conflict.revision,
                decisionSnapshotId: decisionSnapshotID.rawValue,
                expectedRemoteHead: CommandHead(expectedRemoteHead),
                localCandidateSnapshotId: conflict.localSnapshotID.rawValue,
                workId: view.workID.description
            ),
            schemaVersion: 2,
            sourceGeneration: conflict.sourceGeneration,
            sourceSnapshotId: conflict.localSnapshotID.rawValue
        )
        return try SealedCommand.decodeCanonical(CanonicalJSON.encode(envelope))
    }

    func makeClone(
        _ view: V2ImmutableTransferView,
        conflict: V2ConflictCandidate,
        reservation: V2KeepBothReservation,
        remoteHead: V2RemoteHead
    ) throws -> SealedCommand {
        let envelope = CommandEnvelope(
            binding: CommandBinding(binding: view.binding),
            commandId: UUID().uuidString.lowercased(),
            commandKind: "cloneWork",
            payload: CloneWorkPayload(
                conflictId: conflict.conflictID.uuidString.lowercased(),
                conflictRevision: conflict.revision,
                expectedOriginalHead: CommandHead(remoteHead),
                localCandidateSnapshotId: conflict.localSnapshotID.rawValue,
                newDocumentId: reservation.newDocumentID.description,
                newRootSnapshotId: reservation.newRootSnapshotID.rawValue,
                newWorkId: reservation.newWorkID.description,
                sourceWorkId: view.workID.description
            ),
            schemaVersion: 2,
            sourceGeneration: conflict.sourceGeneration,
            sourceSnapshotId: conflict.localSnapshotID.rawValue
        )
        return try SealedCommand.decodeCanonical(CanonicalJSON.encode(envelope))
    }

    func makeCommand(
        kind: String,
        payload: some Encodable,
        view: V2ImmutableTransferView
    ) throws -> SealedCommand {
        let envelope = CommandEnvelope(
            binding: CommandBinding(binding: view.binding),
            commandId: UUID().uuidString.lowercased(),
            commandKind: kind,
            payload: payload,
            schemaVersion: 2,
            sourceGeneration: view.pendingIntent.sourceGeneration,
            sourceSnapshotId: view.pendingIntent.sourceSnapshotID.rawValue
        )
        return try SealedCommand.decodeCanonical(CanonicalJSON.encode(envelope))
    }

    func objectID(_ record: V2SealedCommandRecord) throws -> ObjectID {
        let object = try JSONSerialization.jsonObject(with: record.canonicalRequest)
        guard let dictionary = object as? [String: Any],
              let payload = dictionary["payload"] as? [String: Any],
              let raw = payload["objectId"] as? String else {
            throw SyncV2Failure.fatal(.invalidLocalState)
        }
        return try ObjectID(rawValue: raw)
    }

    func commandSnapshotID(_ record: V2SealedCommandRecord) throws -> SnapshotID {
        let object = try JSONSerialization.jsonObject(with: record.canonicalRequest)
        guard let dictionary = object as? [String: Any],
              let payload = dictionary["payload"] as? [String: Any],
              let raw = payload["snapshotId"] as? String else {
            throw SyncV2Failure.fatal(.invalidLocalState)
        }
        return try SnapshotID(rawValue: raw)
    }

    func makeTransfer(from record: V2SealedCommandRecord, view: V2ImmutableTransferView) async throws -> SyncV2UploadTransfer? {
        let objectID = try objectID(record)
        if let stored = try await store.uploadTransfer(commandID: record.commandID, scope: .bound(view.binding)) {
            if stored.lifecycle == "acknowledged" {
                remoteObjectPresence.insert(
                    RemoteObjectPresenceKey(
                        binding: view.binding,
                        workID: view.workID,
                        objectID: stored.objectID
                    )
                )
                return nil
            }
            return SyncV2UploadTransfer(
                transferID: stored.transferID,
                workID: stored.workID,
                uploadID: stored.uploadID,
                objectID: stored.objectID,
                exactBytes: stored.exactBytes,
                acknowledgedOffset: stored.acknowledgedOffset,
                expiresAt: stored.expiresAt,
                capability: stored.capability
            )
        }
        guard let bytes = view.snapshot.objects[objectID],
              let receipt = try await store.receiptReadback(commandID: record.commandID, scope: .bound(view.binding)),
              receipt.result == .applied,
              let object = try JSONSerialization.jsonObject(with: receipt.canonicalResponse) as? [String: Any],
              let uploadRaw = object["uploadId"] as? String, let uploadID = UUID(uuidString: uploadRaw),
              let capability = object["uploadCapability"] as? String, let expiresRaw = object["expiresAt"] as? String,
              let expires = ISO8601DateFormatter().date(from: expiresRaw) else { return nil }
        let transfer = SyncV2UploadTransfer(
            transferID: record.commandID,
            workID: view.workID,
            uploadID: uploadID,
            objectID: objectID,
            exactBytes: bytes,
            acknowledgedOffset: 0,
            expiresAt: expires,
            capability: capability
        )
        try await store.persistUploadTransfer(
            V2UploadTransferRecord(
                transferID: transfer.transferID,
                commandID: record.commandID,
                workID: transfer.workID,
                objectID: transfer.objectID,
                sourceSnapshotID: view.snapshot.snapshotId,
                sourceGeneration: view.pendingIntent.sourceGeneration,
                uploadID: transfer.uploadID,
                capability: transfer.capability,
                exactBytes: transfer.exactBytes,
                bytesDigest: ObjectID(data: transfer.exactBytes),
                acknowledgedOffset: transfer.acknowledgedOffset,
                expiresAt: transfer.expiresAt,
                lifecycle: "prepared"
            ),
            scope: .bound(view.binding)
        )
        return transfer
    }
}

private struct CommandEnvelope<Payload: Encodable>: Encodable {
    let binding: CommandBinding
    let commandId: String
    let commandKind: String
    let payload: Payload
    let schemaVersion: Int
    let sourceGeneration: Int64
    let sourceSnapshotId: String
}

private struct CommandBinding: Encodable {
    let accountFence: String
    let accountId: String
    let protocolEpoch: Int64
    let serverInstanceId: String

    init(binding: V2AccountBinding) {
        accountFence = binding.accountFence
        accountId = binding.accountID
        protocolEpoch = binding.protocolEpoch
        serverInstanceId = binding.serverInstanceID
    }
}

private struct CommandHead: Encodable {
    let generation: Int64
    let snapshotId: String

    init(_ head: V2RemoteHead) {
        generation = head.generation
        snapshotId = head.snapshotID.rawValue
    }
}

private struct PublishPayload: Encodable {
    let candidateSnapshotId: String
    let expectedRemoteHead: CommandHead?
    let workId: String
}

private struct CreateWorkPayload: Encodable { let documentId: String; let workId: String }
private struct PrepareObjectPayload: Encodable { let byteCount: Int; let objectId: String; let workId: String }
private struct FinalizeObjectPayload: Encodable { let byteCount: Int; let objectId: String; let uploadId: String; let workId: String }
private struct RegisterSnapshotPayload: Encodable { let manifestBase64URL: String; let manifestBytesDigest: String; let snapshotId: String; let workId: String }
private struct ResolveServerPayload: Encodable {
    let conflictId: String
    let conflictRevision: Int64
    let expectedCurrentSnapshotId: String
    let expectedLocalGeneration: Int64
    let preAdoptionSnapshotId: String
    let remoteSnapshotId: String
    let workId: String
}

private struct ResolveDevicePayload: Encodable {
    let conflictId: String
    let conflictRevision: Int64
    let decisionSnapshotId: String
    let expectedRemoteHead: CommandHead
    let localCandidateSnapshotId: String
    let workId: String
}

private struct CloneWorkPayload: Encodable {
    let conflictId: String
    let conflictRevision: Int64
    let expectedOriginalHead: CommandHead
    let localCandidateSnapshotId: String
    let newDocumentId: String
    let newRootSnapshotId: String
    let newWorkId: String
    let sourceWorkId: String
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
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
