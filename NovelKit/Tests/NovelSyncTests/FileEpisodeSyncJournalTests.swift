import Foundation
import NovelSync
import NovelSyncTesting
import Testing

@Suite("File episode sync journal")
struct FileEpisodeSyncJournalTests {
    @Test("atomic JSON round-trip tolerates additive fields and leaves no fixed temporary file")
    func atomicRoundTrip() async throws {
        let root = temporaryRoot(named: "roundtrip")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let journal = try FileEpisodeSyncJournal(rootURL: root)
        let first = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666661",
            parents: [],
            content: "first"
        )
        let second = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666662",
            parents: [first.revisionID],
            content: "second"
        )
        let record = try EpisodeSyncJournalRecord(
            key: SyncTestValues.key,
            branchID: SyncTestValues.branchID,
            lastKnownRemoteHead: first,
            localHead: second,
            pendingRevisions: [second]
        )
        try await journal.save(record)
        #expect(try await journal.load(for: SyncTestValues.key) == record)

        let fileURL = recordURL(root: root)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        object["futureAdditiveField"] = ["safe": true]
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL, options: .atomic)
        #expect(try await journal.load(for: SyncTestValues.key) == record)

        try await journal.save(record)
        let entries = try FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(entries.map(\.lastPathComponent) == [fileURL.lastPathComponent])
    }

    @Test("filesystem root, file roots, and symbolic-link roots are rejected")
    func unsafeRootsAreRejected() throws {
        #expect(throws: EpisodeSyncJournalError.self) {
            _ = try FileEpisodeSyncJournal(rootURL: URL(fileURLWithPath: "/", isDirectory: true))
        }

        let parent = temporaryRoot(named: "unsafe").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fileRoot = parent.appendingPathComponent("file-root")
        try Data("not a directory".utf8).write(to: fileRoot)
        #expect(throws: EpisodeSyncJournalError.self) {
            _ = try FileEpisodeSyncJournal(rootURL: fileRoot)
        }

        let realRoot = parent.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
        let linkedRoot = parent.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        #expect(throws: EpisodeSyncJournalError.self) {
            _ = try FileEpisodeSyncJournal(rootURL: linkedRoot)
        }
    }

    @Test("an existing parent symlink is canonicalized before the journal root is fixed")
    func parentSymlinkIsCanonicalized() async throws {
        let container = temporaryRoot(named: "parent-link").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: container) }
        let firstTarget = container.appendingPathComponent("first-target", isDirectory: true)
        let secondTarget = container.appendingPathComponent("second-target", isDirectory: true)
        try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)

        let parentAlias = container.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: firstTarget)
        let journal = try FileEpisodeSyncJournal(
            rootURL: parentAlias.appendingPathComponent("journal", isDirectory: true)
        )

        try FileManager.default.removeItem(at: parentAlias)
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: secondTarget)
        let revision = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666669",
            parents: [],
            content: "fixed target"
        )
        let record = try EpisodeSyncJournalRecord(
            key: SyncTestValues.key,
            branchID: SyncTestValues.branchID,
            lastKnownRemoteHead: revision,
            localHead: revision
        )
        try await journal.save(record)

        let firstRecord = recordURL(root: firstTarget.appendingPathComponent("journal"))
        let secondRecord = recordURL(root: secondTarget.appendingPathComponent("journal"))
        #expect(FileManager.default.fileExists(atPath: firstRecord.path))
        #expect(!FileManager.default.fileExists(atPath: secondRecord.path))
        #expect(try await journal.load(for: SyncTestValues.key) == record)
    }

    @Test("a journal file above 64 MiB is rejected before decoding")
    func oversizedFileIsRejected() async throws {
        let root = temporaryRoot(named: "oversized")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let workDirectory = recordURL(root: root).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let fileURL = recordURL(root: root)
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(FileEpisodeSyncJournal.maximumRecordBytes + 1))
        try handle.close()

        let journal = try FileEpisodeSyncJournal(rootURL: root)
        do {
            _ = try await journal.load(for: SyncTestValues.key)
            Issue.record("oversized journal unexpectedly decoded")
        } catch {
            #expect(error as? EpisodeSyncJournalError == .invalidFile)
        }
    }

    @Test("worst-case escaped conflict record remains below 64 MiB and round-trips")
    func worstCaseBoundaryRecord() async throws {
        let root = temporaryRoot(named: "boundary")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let byteCount = EpisodeRevision.maximumContentUTF8Bytes
        let base = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666671",
            parents: [],
            content: String(repeating: "\0", count: byteCount)
        )
        let first = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666672",
            parents: [base.revisionID],
            content: String(repeating: "\u{1}", count: byteCount)
        )
        let second = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666673",
            parents: [first.revisionID],
            content: String(repeating: "\u{2}", count: byteCount)
        )
        let local = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666674",
            parents: [second.revisionID],
            content: String(repeating: "\u{3}", count: byteCount)
        )
        let remote = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666675",
            parents: [base.revisionID],
            content: String(repeating: "\u{4}", count: byteCount)
        )
        let conflict = EpisodeConflict(base: base, local: local, remote: remote)
        let record = try EpisodeSyncJournalRecord(
            key: SyncTestValues.key,
            branchID: SyncTestValues.branchID,
            lastKnownRemoteHead: base,
            localHead: local,
            pendingRevisions: [first, second, local],
            conflict: conflict,
            mode: .forcedFork
        )
        let encoded = try FileEpisodeSyncJournal.makeEncoder().encode(record)
        #expect(encoded.count < FileEpisodeSyncJournal.maximumRecordBytes)

        let journal = try FileEpisodeSyncJournal(rootURL: root)
        try await journal.save(record)
        #expect(try await journal.load(for: SyncTestValues.key) == record)
    }

    @Test("fractional revision dates survive restart and retry the same mutation ID")
    func fractionalDateIdempotentRetry() async throws {
        let root = temporaryRoot(named: "idempotency")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = InMemoryEpisodeSyncServer()
        let journal = try FileEpisodeSyncJournal(rootURL: root)
        let original = EpisodeSyncCoordinator(
            key: SyncTestValues.key,
            replicaID: SyncTestValues.replicaA,
            sessionID: SyncTestValues.sessionA,
            transport: server,
            journal: journal
        )
        _ = try await original.link(
            localContent: "base",
            createdAt: SyncTestValues.date.addingTimeInterval(0.875),
            leaseExpiresAt: SyncTestValues.expiry.addingTimeInterval(0.625)
        )
        _ = try await original.recordLocalContent(
            "fractional commit",
            createdAt: SyncTestValues.date.addingTimeInterval(1.875)
        )
        await server.loseNextPublishResponseAfterCommit()
        _ = try await original.synchronize()
        let sealedBeforeRestart = try #require(
            try await journal.load(for: SyncTestValues.key)?.sealedPublish
        )

        let restarted = EpisodeSyncCoordinator(
            key: SyncTestValues.key,
            replicaID: SyncTestValues.replicaA,
            sessionID: SyncEditSessionID(),
            transport: server,
            journal: journal
        )
        _ = try await restarted.restore()
        let retried = try await restarted.synchronize()
        #expect(syncContext(from: retried)?.pendingRevisionCount == 0)
        #expect(await server.currentHead(for: SyncTestValues.key)?.content == "fractional commit")
        #expect(try await journal.load(for: SyncTestValues.key)?.sealedPublish == nil)
        #expect(sealedBeforeRestart.mutationID.rawValue.uuidString.count == 36)
        do {
            _ = try await restarted.recordLocalContent(
                "must claim first",
                createdAt: SyncTestValues.date.addingTimeInterval(3)
            )
            Issue.record("fresh session inherited old writer authority")
        } catch {
            #expect(error as? EpisodeSyncCoordinatorError == .noEditingAuthority)
        }
    }

    private func temporaryRoot(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NovelSyncTests-\(name)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal", isDirectory: true)
    }

    private func recordURL(root: URL) -> URL {
        root
            .appendingPathComponent(SyncTestValues.workID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent("\(SyncTestValues.episodeID.rawValue.uuidString).json")
    }
}
