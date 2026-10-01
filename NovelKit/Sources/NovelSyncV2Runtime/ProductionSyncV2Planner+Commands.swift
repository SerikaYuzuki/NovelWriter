import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store

extension ProductionSyncV2Planner {
    func makeCreateWork(_ view: V2ImmutableTransferView) throws -> SealedCommand {
        try makeCommand(kind: .createWork, payload: CreateWorkPayload(documentId: view.summary.documentID.description, workId: view.workID.description), view: view)
    }

    func makeObjectCommand(
        kind: SyncV2CommandKind,
        objectID: ObjectID,
        view: V2ImmutableTransferView,
        uploadID: UUID? = nil
    ) throws -> SealedCommand {
        if kind == .prepareObject {
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
            kind: .registerSnapshot,
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
            kind: .resolveServer,
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
        kind: SyncV2CommandKind,
        payload: some Encodable,
        view: V2ImmutableTransferView
    ) throws -> SealedCommand {
        let envelope = CommandEnvelope(
            binding: CommandBinding(binding: view.binding),
            commandId: UUID().uuidString.lowercased(),
            commandKind: kind.rawValue,
            payload: payload,
            schemaVersion: 2,
            sourceGeneration: view.sourceGeneration,
            sourceSnapshotId: view.snapshot.snapshotId.rawValue
        )
        return try SealedCommand.decodeCanonical(CanonicalJSON.encode(envelope))
    }

    func objectID(_ record: V2SealedCommandRecord) throws -> ObjectID {
        try SealedCommand.decodeCanonical(record.canonicalRequest).payload.object("objectId")
    }

    func commandSnapshotID(_ record: V2SealedCommandRecord) throws -> SnapshotID {
        try SealedCommand.decodeCanonical(record.canonicalRequest).payload.snapshot("snapshotId")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
