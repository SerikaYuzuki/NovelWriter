// Near-cap round-trip is intentionally written as one explicit reachable-state construction.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable function_body_length optional_data_string_conversion
import Foundation
import NovelCore
import NovelSync
import NovelSyncLegacy
import Testing

@Suite("File whole-work sync journal")
struct FileWorkSyncJournalTests {
    @Test("canonical v1 snapshot fixture is byte-exact and round-trips")
    func snapshotFixture() throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "work-snapshot-v1", withExtension: "json")
        )
        let fixtureFile = try Data(contentsOf: fixtureURL)
        let fixture = fixtureFile.last == 0x0A ? Data(fixtureFile.dropLast()) : fixtureFile
        let document = NovelDocument(
            id: WorkTestValues.documentID,
            title: "Fixture",
            chapters: []
        )
        let encoded = try WorkCanonicalJSON.encodeSnapshot(WorkSnapshot(document: document))
        #expect(fixture == encoded)
        #expect(try WorkCanonicalJSON.decodeSnapshot(fixture).materializedDocument() == document)
    }

    @Test("file journal atomically round-trips and revision table deduplicates shared snapshots")
    func atomicDeduplicatedRoundTrip() async throws {
        let root = temporaryWorkRoot("roundtrip")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let journal = try FileWorkSyncJournal(rootURL: root)
        let revision = try WorkTestValues.revision(
            snapshot: WorkTestValues.snapshot(),
            id: "70000000-0000-0000-0000-000000000020"
        )
        let record = try WorkSyncJournalRecord(
            workID: WorkTestValues.workID,
            localWorkingCopyID: WorkTestValues.copyA,
            replicaID: WorkTestValues.replicaA,
            branchID: WorkTestValues.branch,
            lastKnownRemoteHead: revision,
            localHead: revision,
            outbox: [],
            reconciliationStatus: .synchronized
        )
        try await journal.save(record)
        #expect(try await journal.load(for: WorkTestValues.workID) == record)

        let data = try Data(contentsOf: workRecordURL(root: root))
        let expected = try FileWorkSyncJournal.makeEncoder().encode(record)
        #expect(occurrences(of: "\"snapshotVersion\"", in: data) == 1)
        #expect(data == expected)
    }

    @Test("noncanonical and unknown journal members are rejected")
    func nonCanonicalJournalRejected() async throws {
        let root = temporaryWorkRoot("noncanonical")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let journal = try FileWorkSyncJournal(rootURL: root)
        let revision = try WorkTestValues.revision(
            snapshot: WorkTestValues.snapshot(),
            id: "70000000-0000-0000-0000-000000000021"
        )
        let record = try WorkSyncJournalRecord(
            workID: WorkTestValues.workID,
            localWorkingCopyID: WorkTestValues.copyA,
            replicaID: WorkTestValues.replicaA,
            branchID: WorkTestValues.branch,
            lastKnownRemoteHead: nil,
            localHead: revision,
            outbox: [revision]
        )
        try await journal.save(record)
        let url = workRecordURL(root: root)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try pretty.write(to: url, options: .atomic)
        await #expect(throws: WorkSyncJournalError.self) {
            _ = try await journal.load(for: WorkTestValues.workID)
        }
    }

    @Test("preflight rejects sparse file above cap without decoding")
    func oversizedFileRejected() async throws {
        let root = temporaryWorkRoot("oversized")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = workRecordURL(root: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(FileWorkSyncJournal.maximumRecordByteCount + 1))
        try handle.close()
        let journal = try FileWorkSyncJournal(rootURL: root)
        await #expect(throws: WorkSyncJournalError.self) {
            _ = try await journal.load(for: WorkTestValues.workID)
        }
    }

    @Test("bounded state algebra leaves file-cap headroom with and without a proposed review snapshot")
    func boundedStateAlgebra() {
        let withoutReview = WorkSyncJournalRecord.maximumStoredRevisionCount
            * WorkRevision.maximumCanonicalByteCount
        let withReview = WorkSyncJournalRecord.maximumStoredRevisionCount
            * WorkRevision.maximumCanonicalByteCount
            + WorkSnapshot.maximumCanonicalByteCount
            + WorkSyncJournalRecord.maximumConflictCount
            * WorkFieldConflict.maximumValueUTF8Bytes * 4
        #expect(withoutReview < FileWorkSyncJournal.maximumRecordByteCount)
        #expect(withReview < FileWorkSyncJournal.maximumRecordByteCount)
        #expect(WorkSyncJournalRecord.maximumOutboxRevisionCount == 3)
    }

    @Test("reachable five-revision review near cap encodes, saves, and loads without dropping evidence")
    func reachableNearCapReviewRoundTrip() async throws {
        let root = temporaryWorkRoot("near-cap-review")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let largeBody = String(
            repeating: "x",
            count: WorkSnapshot.maximumStringUTF8Bytes - 512
        )
        let episodes = (0 ..< 43).map { index in
            Episode(title: "episode-\(index)", content: largeBody)
        }
        let snapshot = try WorkSnapshot(document: NovelDocument(
            id: WorkTestValues.documentID,
            title: "near cap",
            chapters: [Chapter(title: "large", episodes: episodes)]
        ))
        func revision(
            parents: [SyncRevisionID],
            offset: TimeInterval
        ) throws -> WorkRevision {
            try WorkRevision(
                workID: WorkTestValues.workID,
                parentRevisionIDs: parents,
                branchID: WorkTestValues.branch,
                authorReplicaID: WorkTestValues.replicaA,
                authorSessionID: WorkTestValues.sessionA,
                snapshot: snapshot,
                clientCreatedAt: WorkTestValues.date.addingTimeInterval(offset)
            )
        }
        let base = try revision(parents: [], offset: 0)
        let local = try revision(parents: [base.revisionID], offset: 1)
        let remote = try revision(parents: [base.revisionID], offset: 2)
        let retained = try revision(parents: [base.revisionID], offset: 3)
        let staged = try revision(parents: [local.revisionID], offset: 4)
        let review = try WorkConflictReview(
            base: base,
            local: local,
            remote: remote,
            proposedSnapshot: snapshot,
            conflicts: [
                WorkFieldConflict(
                    path: "document.title",
                    entityKind: .document,
                    entityID: nil,
                    field: "title",
                    reason: .sameFieldChanged,
                    baseValue: "base",
                    localValue: "local",
                    remoteValue: "remote",
                    proposedValue: "local"
                )
            ]
        )
        let record = try WorkSyncJournalRecord(
            workID: WorkTestValues.workID,
            localWorkingCopyID: WorkTestValues.copyA,
            replicaID: WorkTestValues.replicaA,
            branchID: WorkTestValues.branch,
            lastKnownRemoteHead: remote,
            localHead: local,
            outbox: [local],
            stagedLocalRevision: staged,
            retainedLocalRecoveryRevision: retained,
            conflictReview: review,
            reconciliationStatus: .materializationRequired
        )
        let journal = try FileWorkSyncJournal(rootURL: root)
        try await journal.save(record)
        let fileSize = try #require(
            FileManager.default.attributesOfItem(atPath: workRecordURL(root: root).path)[.size]
                as? NSNumber
        ).intValue
        print("reachable near-cap work journal bytes: \(fileSize)")
        #expect(fileSize > 256 * 1024 * 1024)
        #expect(fileSize < FileWorkSyncJournal.maximumRecordByteCount)
        #expect(try await journal.load(for: WorkTestValues.workID) == record)
    }
}

private func temporaryWorkRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fuminiwa-work-sync-\(name)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("journal", isDirectory: true)
}

private func workRecordURL(root: URL) -> URL {
    root
        .appendingPathComponent(WorkTestValues.workID.rawValue.uuidString, isDirectory: true)
        .appendingPathComponent("work-sync.json")
}

private func occurrences(of needle: String, in data: Data) -> Int {
    String(decoding: data, as: UTF8.self).components(separatedBy: needle).count - 1
}
