import Foundation
import NovelSyncV2

extension InMemorySyncV2RuntimeState {
    func makeCommand(
        workID: WorkID,
        intent: Intent,
        account: TestAccount
    ) throws -> SealedCommand {
        switch intent.kind {
        case .checkpoint:
            try makePublish(workID: workID, intent: intent, account: account)
        case let .conflict(action):
            try makeConflictCommand(
                workID: workID,
                intent: intent,
                action: action,
                account: account
            )
        case let .restore(selected, previous):
            try makeRestoreCommand(
                workID: workID,
                intent: intent,
                selected: selected,
                previous: previous,
                account: account
            )
        }
    }
}

private extension InMemorySyncV2RuntimeState {
    func makePublish(
        workID: WorkID,
        intent: Intent,
        account: TestAccount
    ) throws -> SealedCommand {
        let value = CommandEnvelope(
            binding: CommandBinding(account: account),
            commandId: UUID().uuidString.lowercased(),
            commandKind: "publish",
            payload: PublishPayload(
                candidateSnapshotId: intent.snapshotID.rawValue,
                expectedRemoteHead: .none,
                workId: workID.description
            ),
            schemaVersion: 2,
            sourceGeneration: intent.generation,
            sourceSnapshotId: intent.snapshotID.rawValue
        )
        return try SealedCommand.decodeCanonical(CanonicalJSON.encode(value))
    }

    func makeConflictCommand(
        workID: WorkID,
        intent: Intent,
        action: SyncV2ConflictAction,
        account: TestAccount
    ) throws -> SealedCommand {
        let binding = CommandBinding(account: account)
        let commandID = UUID().uuidString.lowercased()
        let remoteHead = NullableHead.value(CommandHead(
            generation: 1,
            snapshotId: action.remoteSnapshotID.rawValue
        ))
        let data: Data = switch action.choice {
        case .useDevice:
            try CanonicalJSON.encode(CommandEnvelope(
                binding: binding,
                commandId: commandID,
                commandKind: "resolveDevice",
                payload: ResolveDevicePayload(
                    conflictId: action.conflictID.uuidString.lowercased(),
                    conflictRevision: action.revision,
                    decisionSnapshotId: intent.snapshotID.rawValue,
                    expectedRemoteHead: remoteHead,
                    localCandidateSnapshotId: action.localSnapshotID.rawValue,
                    workId: workID.description
                ),
                schemaVersion: 2,
                sourceGeneration: intent.generation,
                sourceSnapshotId: intent.snapshotID.rawValue
            ))
        case .useServer:
            try CanonicalJSON.encode(CommandEnvelope(
                binding: binding,
                commandId: commandID,
                commandKind: "resolveServer",
                payload: ResolveServerPayload(
                    conflictId: action.conflictID.uuidString.lowercased(),
                    conflictRevision: action.revision,
                    expectedCurrentSnapshotId: action.localSnapshotID.rawValue,
                    expectedLocalGeneration: action.sourceGeneration,
                    preAdoptionSnapshotId: action.localSnapshotID.rawValue,
                    remoteSnapshotId: action.remoteSnapshotID.rawValue,
                    workId: workID.description
                ),
                schemaVersion: 2,
                sourceGeneration: intent.generation,
                sourceSnapshotId: intent.snapshotID.rawValue
            ))
        case .keepBoth:
            try makeCloneCommand(
                workID: workID,
                intent: intent,
                action: action,
                binding: binding,
                commandID: commandID,
                remoteHead: remoteHead
            )
        }
        return try SealedCommand.decodeCanonical(data)
    }

    func makeCloneCommand(
        workID: WorkID,
        intent: Intent,
        action: SyncV2ConflictAction,
        binding: CommandBinding,
        commandID: String,
        remoteHead: NullableHead
    ) throws -> Data {
        guard let newWorkID = action.newWorkID,
              let newDocumentID = action.newDocumentID else {
            throw SyncV2Failure.fatal(.invalidLocalState)
        }
        let newRoot = SnapshotID(data: Data(
            (intent.snapshotID.rawValue + newWorkID.description).utf8
        ))
        return try CanonicalJSON.encode(CommandEnvelope(
            binding: binding,
            commandId: commandID,
            commandKind: "cloneWork",
            payload: CloneWorkPayload(
                conflictId: action.conflictID.uuidString.lowercased(),
                conflictRevision: action.revision,
                expectedOriginalHead: remoteHead,
                localCandidateSnapshotId: action.localSnapshotID.rawValue,
                newDocumentId: newDocumentID.description,
                newRootSnapshotId: newRoot.rawValue,
                newWorkId: newWorkID.description,
                sourceWorkId: workID.description
            ),
            schemaVersion: 2,
            sourceGeneration: intent.generation,
            sourceSnapshotId: intent.snapshotID.rawValue
        ))
    }

    func makeRestoreCommand(
        workID: WorkID,
        intent: Intent,
        selected: SnapshotID,
        previous: SnapshotID,
        account: TestAccount
    ) throws -> SealedCommand {
        let value = CommandEnvelope(
            binding: CommandBinding(account: account),
            commandId: UUID().uuidString.lowercased(),
            commandKind: "restore",
            payload: RestorePayload(
                expectedCurrentSnapshotId: previous.rawValue,
                expectedLocalGeneration: max(1, intent.generation - 1),
                expectedRemoteHead: .none,
                newSnapshotId: intent.snapshotID.rawValue,
                selectedSnapshotId: selected.rawValue,
                workId: workID.description
            ),
            schemaVersion: 2,
            sourceGeneration: intent.generation,
            sourceSnapshotId: intent.snapshotID.rawValue
        )
        return try SealedCommand.decodeCanonical(CanonicalJSON.encode(value))
    }
}

private struct CommandBinding: Encodable {
    let accountFence: String
    let accountId: String
    let protocolEpoch: Int
    let serverInstanceId: String

    init(account: TestAccount) {
        accountFence = account.accountFence
        accountId = account.accountID
        protocolEpoch = 2
        serverInstanceId = "test-server"
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

private struct CommandHead: Encodable {
    let generation: Int64
    let snapshotId: String
}

private enum NullableHead: Encodable {
    case none
    case value(CommandHead)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .none:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .value(head):
            try head.encode(to: encoder)
        }
    }
}

private struct PublishPayload: Encodable {
    let candidateSnapshotId: String
    let expectedRemoteHead: NullableHead
    let workId: String
}

private struct ResolveDevicePayload: Encodable {
    let conflictId: String
    let conflictRevision: Int64
    let decisionSnapshotId: String
    let expectedRemoteHead: NullableHead
    let localCandidateSnapshotId: String
    let workId: String
}

private struct ResolveServerPayload: Encodable {
    let conflictId: String
    let conflictRevision: Int64
    let expectedCurrentSnapshotId: String
    let expectedLocalGeneration: Int64
    let preAdoptionSnapshotId: String
    let remoteSnapshotId: String
    let workId: String
}

private struct CloneWorkPayload: Encodable {
    let conflictId: String
    let conflictRevision: Int64
    let expectedOriginalHead: NullableHead
    let localCandidateSnapshotId: String
    let newDocumentId: String
    let newRootSnapshotId: String
    let newWorkId: String
    let sourceWorkId: String
}

private struct RestorePayload: Encodable {
    let expectedCurrentSnapshotId: String
    let expectedLocalGeneration: Int64
    let expectedRemoteHead: NullableHead
    let newSnapshotId: String
    let selectedSnapshotId: String
    let workId: String
}
