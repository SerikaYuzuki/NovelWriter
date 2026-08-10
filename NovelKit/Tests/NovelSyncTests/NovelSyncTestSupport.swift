import Foundation
import NovelCore
import NovelSync

enum SyncTestValues {
    static let workID = SyncWorkID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    static let episodeID = EpisodeID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    static let key = EpisodeSyncKey(workID: workID, episodeID: episodeID)
    static let branchID = SyncBranchID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    static let replicaA = SyncReplicaID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
    static let sessionA = SyncEditSessionID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
    static let replicaB = SyncReplicaID(rawValue: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!)
    static let sessionB = SyncEditSessionID(rawValue: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!)
    static let date = Date(timeIntervalSince1970: 1_754_870_400)
    static let expiry = Date(timeIntervalSince1970: 1_754_874_000)

    static func revision(
        id: String,
        parents: [SyncRevisionID],
        content: String,
        replica: SyncReplicaID = replicaA,
        session: SyncEditSessionID = sessionA,
        branch: SyncBranchID = branchID,
        createdAt: Date = date
    ) throws -> EpisodeRevision {
        try EpisodeRevision(
            key: key,
            revisionID: SyncRevisionID(rawValue: UUID(uuidString: id)!),
            parentRevisionIDs: parents,
            branchID: branch,
            authorReplicaID: replica,
            authorSessionID: session,
            content: content,
            clientCreatedAt: createdAt
        )
    }

    static func authority(
        replica: SyncReplicaID = replicaA,
        session: SyncEditSessionID = sessionA,
        epoch: UInt64
    ) throws -> EpisodeLeaseAuthority {
        try EpisodeLeaseAuthority(holderReplicaID: replica, holderSessionID: session, epoch: epoch)
    }

    static func structureDigest() throws -> SyncWorkStructureDigest {
        try SyncWorkStructureDigest(chapters: [])
    }
}

func syncContext(from state: EpisodeSyncState) -> EpisodeSyncContext? {
    switch state {
    case .unlinked:
        nil
    case let .restoredUnverified(context),
         let .upToDate(context),
         let .localChanges(context),
         let .offlineFork(context),
         let .synchronizing(context):
        context
    case let .authorityGrantedAwaitingInstall(context, _),
         let .readOnly(context, _),
         let .authorityLost(context, _),
         let .remoteUpdateAvailable(context, _),
         let .conflicted(context, _):
        context
    }
}

func syncConflict(from state: EpisodeSyncState) -> EpisodeConflict? {
    guard case let .conflicted(_, conflict) = state else { return nil }
    return conflict
}
