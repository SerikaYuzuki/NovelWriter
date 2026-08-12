import NovelSync

enum CloudKitReceiptResolver {
    static func resolve(
        receipt: CloudKitMutationReceipt,
        committedHead: EpisodeRevision,
        current: EpisodeRemoteSnapshot
    ) throws -> EpisodePublishResult {
        try resolve(
            expectedCommittedRevisionID: receipt.resultHeadRevisionID,
            key: receipt.key,
            committedHead: committedHead,
            current: current
        )
    }

    static func resolve(
        expectedCommittedRevisionID: SyncRevisionID,
        key: EpisodeSyncKey,
        committedHead: EpisodeRevision,
        current: EpisodeRemoteSnapshot
    ) throws -> EpisodePublishResult {
        guard committedHead.key == key,
              committedHead.revisionID == expectedCommittedRevisionID,
              current.head?.key == key || current.head == nil else {
            throw CloudKitSyncAdapterError.invalidRemoteRecord
        }
        return .acknowledged(committedHead: committedHead, current: current)
    }
}
