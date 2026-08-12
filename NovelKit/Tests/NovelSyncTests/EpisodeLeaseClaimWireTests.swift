import Foundation
import NovelSync
import Testing

@Suite("Episode lease claim wire")
struct EpisodeLeaseClaimWireTests {
    @Test("conflict force claim carries an exact portable head CAS and rejects partial constraints")
    func exactHeadLeaseClaimWireContract() throws {
        let remote = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666690",
            parents: [],
            content: "confirmed remote"
        )
        let request = try EpisodeLeaseClaimRequest(
            key: SyncTestValues.key,
            requesterReplicaID: SyncTestValues.replicaA,
            requesterSessionID: SyncTestValues.sessionA,
            expectedEpoch: 7,
            expectedHeadRevisionID: remote.revisionID,
            expectedHeadContentDigest: remote.contentDigest,
            expiresAt: SyncTestValues.expiry,
            kind: .forceTakeover
        )
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(EpisodeLeaseClaimRequest.self, from: data) == request)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["expectedHeadRevisionID"] as? String == remote.revisionID.rawValue.uuidString)
        #expect(object["expectedHeadContentDigest"] as? String == remote.contentDigest.rawValue)
        object.removeValue(forKey: "expectedHeadContentDigest")
        let missingDigest = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(EpisodeLeaseClaimRequest.self, from: missingDigest)
        }

        #expect(throws: EpisodeSyncTransportError.invalidLeaseClaim) {
            _ = try EpisodeLeaseClaimRequest(
                key: SyncTestValues.key,
                requesterReplicaID: SyncTestValues.replicaA,
                requesterSessionID: SyncTestValues.sessionA,
                expectedEpoch: 7,
                expectedHeadRevisionID: remote.revisionID,
                expectedHeadContentDigest: remote.contentDigest,
                expiresAt: SyncTestValues.expiry,
                kind: .acquireOrRenew
            )
        }
        #expect(throws: EpisodeSyncTransportError.invalidLeaseClaim) {
            _ = try EpisodeLeaseClaimRequest(
                key: SyncTestValues.key,
                requesterReplicaID: SyncTestValues.replicaA,
                requesterSessionID: SyncTestValues.sessionA,
                expectedEpoch: nil,
                expiresAt: SyncTestValues.expiry,
                kind: .forceTakeover
            )
        }
    }
}
