import Foundation
import NovelSync
import Testing

@Suite("NovelSync wire and digest")
// Wire rejection cases stay grouped so every portable DTO is audited together.
// swiftlint:disable:next type_body_length
struct SyncCodableAndDigestTests {
    @Test("SHA-256 known vectors remain stable")
    func sha256KnownVectors() {
        #expect(
            SyncContentDigest(content: "").rawValue
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        #expect(
            SyncContentDigest(content: "abc").rawValue
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            SyncContentDigest(content: "日本語😀").rawValue
                == "94817f31083740f98f4b518e6989116e8aa08d8c6b76966abc057cc495564a17"
        )
    }

    @Test("revision v1 golden fixture uses canonical string IDs and tolerates additive fields")
    func revisionGoldenFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "episode-revision-v1", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let revision = try JSONDecoder().decode(EpisodeRevision.self, from: data)

        #expect(revision.key == SyncTestValues.key)
        #expect(revision.content == "本文\n😀")
        #expect(revision.contentDigest == SyncContentDigest(content: revision.content))

        let encoded = try JSONEncoder().encode(revision)
        #expect(try jsonObject(from: encoded) == jsonObject(from: data))

        var additive = try #require(jsonObject(from: data) as? [String: Any])
        additive["futureField"] = ["safe": true]
        let additiveData = try JSONSerialization.data(withJSONObject: additive)
        #expect(try FileEpisodeSyncJournal.makeDecoder().decode(EpisodeRevision.self, from: additiveData) == revision)
    }

    @Test("timestamps use canonical RFC 3339 whole-second strings with plain Codable")
    func canonicalTimestamps() throws {
        let revision = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666666",
            parents: [],
            content: "wire",
            createdAt: Date(timeIntervalSince1970: 1_754_870_400.999)
        )
        let authority = try SyncTestValues.authority(epoch: 1)
        let lease = EpisodeLease(
            authority: authority,
            expiresAt: Date(timeIntervalSince1970: 1_754_874_000.999)
        )
        let request = try EpisodeLeaseClaimRequest(
            key: SyncTestValues.key,
            requesterReplicaID: SyncTestValues.replicaA,
            requesterSessionID: SyncTestValues.sessionA,
            expectedEpoch: 1,
            expiresAt: lease.expiresAt,
            kind: .acquireOrRenew
        )

        let revisionObject = try #require(jsonObject(from: JSONEncoder().encode(revision)) as? [String: Any])
        let leaseObject = try #require(jsonObject(from: JSONEncoder().encode(lease)) as? [String: Any])
        let requestObject = try #require(jsonObject(from: JSONEncoder().encode(request)) as? [String: Any])
        #expect(revisionObject["clientCreatedAt"] as? String == "2025-08-11T00:00:00Z")
        #expect(leaseObject["expiresAt"] as? String == "2025-08-11T01:00:00Z")
        #expect(requestObject["expiresAt"] as? String == "2025-08-11T01:00:00Z")

        for noncanonical in [
            "2025-08-11T00:00:00.000Z",
            "2025-08-11T09:00:00+09:00",
            "2025-08-11t00:00:00z"
        ] {
            var object = revisionObject
            object["clientCreatedAt"] = noncanonical
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(EpisodeRevision.self, from: data)
            }
        }
    }

    @Test("sync IDs reject lowercase, object-shaped, and noncanonical UUID wire values")
    func canonicalUUIDOnly() throws {
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(SyncWorkID.self, from: Data("\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\"".utf8))
        }
        #expect(throws: DecodingError.self) {
            let objectShapedID = Data(
                "{\"rawValue\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\"}".utf8
            )
            _ = try decoder.decode(SyncWorkID.self, from: objectShapedID)
        }

        let malformedKey = Data(
            """
            {"workID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",\
            "episodeID":{"rawValue":"11111111-1111-1111-1111-111111111111"}}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(EpisodeSyncKey.self, from: malformedKey)
        }
    }

    @Test("descriptor source document hint is canonical and not remote identity")
    func descriptorCanonicalSourceID() throws {
        let descriptor = try SyncWorkDescriptor(
            workID: SyncTestValues.workID,
            sourceDocumentID: #require(UUID(uuidString: "99999999-9999-9999-9999-999999999999")),
            structureDigest: SyncTestValues.structureDigest(),
            title: "作品"
        )
        let encoded = try JSONEncoder().encode(descriptor)
        let object = try #require(jsonObject(from: encoded) as? [String: Any])
        #expect(object["workID"] as? String == SyncTestValues.workID.rawValue.uuidString)
        #expect(object["sourceDocumentID"] as? String == "99999999-9999-9999-9999-999999999999")

        let lowercase = Data(
            """
            {"protocolVersion":1,"workID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",\
            "sourceDocumentID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",\
            "structureDigest":"46064d31bb08f555390518fff8643f5983c2d9fe65303c84bed043c7f93c3fbf",\
            "title":"作品"}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SyncWorkDescriptor.self, from: lowercase)
        }
    }

    @Test("revision content accepts 1 MiB and rejects larger input without truncation")
    func revisionContentCap() throws {
        let boundary = String(repeating: "a", count: EpisodeRevision.maximumContentUTF8Bytes)
        let revision = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666666",
            parents: [],
            content: boundary
        )
        #expect(revision.content.utf8.count == EpisodeRevision.maximumContentUTF8Bytes)

        let oversized = boundary + "a"
        #expect(throws: EpisodeRevisionError.self) {
            _ = try SyncTestValues.revision(
                id: "66666666-6666-6666-6666-666666666667",
                parents: [],
                content: oversized
            )
        }

        let validData = try FileEpisodeSyncJournal.makeEncoder().encode(
            SyncTestValues.revision(
                id: "66666666-6666-6666-6666-666666666668",
                parents: [],
                content: "small"
            )
        )
        var object = try #require(jsonObject(from: validData) as? [String: Any])
        object["content"] = oversized
        let oversizedData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: EpisodeRevisionError.self) {
            _ = try FileEpisodeSyncJournal.makeDecoder().decode(EpisodeRevision.self, from: oversizedData)
        }
    }

    @Test("lease epoch outside signed 64-bit wire range fails closed")
    func leaseEpochCap() {
        let data = Data(
            """
            {"holderReplicaID":"33333333-3333-3333-3333-333333333333",\
            "holderSessionID":"44444444-4444-4444-4444-444444444444",\
            "epoch":9223372036854775808}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(EpisodeLeaseAuthority.self, from: data)
        }
    }

    @Test("revision parent cap is enforced while decoding untrusted wire data")
    func revisionParentDecodeCap() throws {
        let revision = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666691",
            parents: [],
            content: "wire"
        )
        var object = try #require(
            jsonObject(from: JSONEncoder().encode(revision)) as? [String: Any]
        )
        object["parentRevisionIDs"] = [
            "55555555-5555-5555-5555-555555555551",
            "55555555-5555-5555-5555-555555555552",
            "55555555-5555-5555-5555-555555555553"
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: EpisodeRevisionError.self) {
            _ = try JSONDecoder().decode(EpisodeRevision.self, from: data)
        }
    }

    @Test("publish batch cap is enforced while decoding untrusted wire data")
    func publishBatchDecodeCap() throws {
        let revision = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666692",
            parents: [],
            content: "wire"
        )
        let request = try EpisodePublishRequest(
            key: SyncTestValues.key,
            revisions: [revision],
            candidateHeadRevisionID: revision.revisionID,
            expectedHeadRevisionID: nil,
            expectedLeaseAuthority: SyncTestValues.authority(epoch: 1)
        )
        var object = try #require(
            jsonObject(from: JSONEncoder().encode(request)) as? [String: Any]
        )
        let revisions = try #require(object["revisions"] as? [Any])
        let template = try #require(revisions.first)
        object["revisions"] = (0 ... EpisodePublishRequest.maximumRevisionCount).map { _ in template }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(EpisodePublishRequest.self, from: data)
        }
    }

    @Test("journal pending cap is enforced while decoding app-private data")
    func journalPendingDecodeCap() throws {
        let revision = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666693",
            parents: [],
            content: "wire"
        )
        let record = try EpisodeSyncJournalRecord(
            key: SyncTestValues.key,
            branchID: SyncTestValues.branchID,
            lastKnownRemoteHead: revision,
            localHead: revision
        )
        var object = try #require(
            jsonObject(from: FileEpisodeSyncJournal.makeEncoder().encode(record)) as? [String: Any]
        )
        let template = try #require(object["localHead"])
        object["pendingRevisions"] = (
            0 ... EpisodeSyncJournalRecord.maximumPendingRevisionCount
        ).map { _ in template }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: EpisodeSyncJournalError.self) {
            _ = try JSONDecoder().decode(EpisodeSyncJournalRecord.self, from: data)
        }
    }

    @Test("every top-level sync wire DTO rejects an unknown protocol major")
    func unknownProtocolVersionFailsClosed() throws {
        let revision = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666666",
            parents: [],
            content: "wire"
        )
        let authority = try SyncTestValues.authority(epoch: 1)
        let lease = EpisodeLease(authority: authority, expiresAt: SyncTestValues.expiry)
        let snapshot = try EpisodeRemoteSnapshot(head: revision, leaseEpoch: 1, lease: lease)
        let claimRequest = try EpisodeLeaseClaimRequest(
            key: SyncTestValues.key,
            requesterReplicaID: SyncTestValues.replicaA,
            requesterSessionID: SyncTestValues.sessionA,
            expectedEpoch: 1,
            expiresAt: SyncTestValues.expiry,
            kind: .acquireOrRenew
        )
        let publishRequest = try EpisodePublishRequest(
            key: SyncTestValues.key,
            revisions: [revision],
            candidateHeadRevisionID: revision.revisionID,
            expectedHeadRevisionID: nil,
            expectedLeaseAuthority: authority
        )
        let descriptor = try SyncWorkDescriptor(
            workID: SyncTestValues.workID,
            sourceDocumentID: #require(UUID(uuidString: "99999999-9999-9999-9999-999999999999")),
            structureDigest: SyncTestValues.structureDigest(),
            title: "作品"
        )

        try expectUnknownVersionRejected(revision)
        try expectUnknownVersionRejected(snapshot)
        try expectUnknownVersionRejected(claimRequest)
        try expectUnknownVersionRejected(EpisodeLeaseClaimResult.granted(snapshot))
        try expectUnknownVersionRejected(publishRequest)
        try expectUnknownVersionRejected(
            EpisodePublishResult.acknowledged(committedHead: revision, current: snapshot)
        )
        try expectUnknownVersionRejected(descriptor)
    }

    private func jsonObject(from data: Data) throws -> AnyHashable {
        try #require(JSONSerialization.jsonObject(with: data) as? AnyHashable)
    }

    private func expectUnknownVersionRejected<Value: Codable>(_ value: Value) throws {
        let encoded = try FileEpisodeSyncJournal.makeEncoder().encode(value)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["protocolVersion"] = 2
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SyncWireError.self) {
            _ = try FileEpisodeSyncJournal.makeDecoder().decode(Value.self, from: unsupported)
        }
    }
}
