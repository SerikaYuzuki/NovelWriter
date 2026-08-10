import CloudKit
import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit

let cloudTestWorkID = SyncWorkID(
    rawValue: UUID(uuidString: "4D875891-E4A9-45CC-B0E3-9CB9024EAA18")!
)
let cloudTestEpisodeID = EpisodeID(
    rawValue: UUID(uuidString: "635158B4-E377-4D24-9338-9691442CFF94")!
)
let cloudTestKey = EpisodeSyncKey(workID: cloudTestWorkID, episodeID: cloudTestEpisodeID)
let cloudTestReplicaID = SyncReplicaID(
    rawValue: UUID(uuidString: "8B4D8AF4-64B5-4611-81F3-E10DD82A302C")!
)
let cloudTestSessionID = SyncEditSessionID(
    rawValue: UUID(uuidString: "5FFBFE99-90FE-4D0B-ACF9-D3D26475A756")!
)
let cloudTestBranchID = SyncBranchID(
    rawValue: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
)
let cloudTestDate = Date(timeIntervalSince1970: 1_787_000_000)

func makeCloudTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FUMINIWA-CloudKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

func removeCloudTestDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

func makeCloudTestRevision(
    id: UUID,
    parents: [SyncRevisionID],
    content: String,
    authorReplicaID: SyncReplicaID = cloudTestReplicaID,
    authorSessionID: SyncEditSessionID = cloudTestSessionID,
    createdAt: Date = cloudTestDate
) throws -> EpisodeRevision {
    try EpisodeRevision(
        key: cloudTestKey,
        revisionID: SyncRevisionID(rawValue: id),
        parentRevisionIDs: parents,
        branchID: cloudTestBranchID,
        authorReplicaID: authorReplicaID,
        authorSessionID: authorSessionID,
        content: content,
        clientCreatedAt: createdAt
    )
}

func makeCloudTestLease(epoch: UInt64 = 12) throws -> EpisodeLease {
    let authority = try EpisodeLeaseAuthority(
        holderReplicaID: cloudTestReplicaID,
        holderSessionID: cloudTestSessionID,
        epoch: epoch
    )
    return EpisodeLease(authority: authority, expiresAt: cloudTestDate.addingTimeInterval(300))
}
