import Foundation
import NovelSyncV2
import NovelSyncV2Store

extension ProductionSyncV2Planner {
    func makeRestore(_ view: V2ImmutableTransferView, source: V2RestoreCommandSource) throws -> SealedCommand {
        let payload = RestorePayload(
            expectedCurrentSnapshotId: source.previousSnapshotID.rawValue,
            expectedLocalGeneration: source.previousGeneration,
            expectedRemoteHead: source.expectedRemoteHead.map(CommandHead.init),
            newSnapshotId: source.restoredSnapshotID.rawValue,
            selectedSnapshotId: source.selectedSnapshotID.rawValue,
            workId: view.workID.description
        )
        return try SealedCommand.decodeCanonical(CanonicalJSON.encode(CommandEnvelope(
            binding: CommandBinding(binding: view.binding), commandId: UUID().uuidString.lowercased(),
            commandKind: "restore", payload: payload, schemaVersion: 2,
            sourceGeneration: source.previousGeneration, sourceSnapshotId: source.previousSnapshotID.rawValue
        )))
    }
}

private struct RestorePayload: Encodable {
    let expectedCurrentSnapshotId: String
    let expectedLocalGeneration: Int64
    let expectedRemoteHead: CommandHead?
    let newSnapshotId: String
    let selectedSnapshotId: String
    let workId: String

    enum CodingKeys: String, CodingKey {
        case expectedCurrentSnapshotId, expectedLocalGeneration, expectedRemoteHead, newSnapshotId, selectedSnapshotId, workId
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedCurrentSnapshotId, forKey: .expectedCurrentSnapshotId)
        try container.encode(expectedLocalGeneration, forKey: .expectedLocalGeneration)
        try container.encode(newSnapshotId, forKey: .newSnapshotId)
        try container.encode(selectedSnapshotId, forKey: .selectedSnapshotId)
        try container.encode(workId, forKey: .workId)
        if let expectedRemoteHead {
            try container.encode(expectedRemoteHead, forKey: .expectedRemoteHead)
        } else {
            try container.encodeNil(forKey: .expectedRemoteHead)
        }
    }
}
