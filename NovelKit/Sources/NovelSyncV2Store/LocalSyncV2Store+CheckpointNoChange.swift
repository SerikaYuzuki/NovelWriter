import Foundation
import NovelCore
import NovelSyncV2

extension LocalSyncV2Store {
    func checkpointContentMatches(
        workID: WorkID,
        current: SnapshotID,
        candidate: EncodedSnapshot
    ) throws -> Bool {
        let previous = try loadEncoded(workID: workID, snapshotID: current)
        return previous.manifest.entries == candidate.manifest.entries &&
            previous.objects == candidate.objects
    }

    func commitNoChangeCheckpoint(
        _ request: V2CheckpointRequest,
        scope: V2LocalWorkScope,
        current: SnapshotID,
        anchor: String
    ) throws -> V2CheckpointResult {
        try inTransaction {
            guard let latest = try scopedWorkRow(
                workID: request.workID,
                scope: scope
            ),
                latest[1].text == DocumentID(request.document.id).description,
                latest[2].int64 == request.expectedGeneration,
                latest[3].blob == current.bytes,
                latest[5].text == anchor else {
                throw SyncV2StoreError.generationMismatch
            }
            if request.reason.protectsOccurrence {
                try insertHistory(
                    workID: request.workID,
                    snapshotID: current,
                    reason: request.reason.rawValue,
                    pinned: true,
                    generation: request.expectedGeneration
                )
            }
            return try V2CheckpointResult(
                snapshotID: current,
                generation: request.expectedGeneration,
                intentID: latestPendingIntentID(
                    workID: request.workID,
                    scope: scope
                ),
                noChanges: true
            )
        }
    }
}
