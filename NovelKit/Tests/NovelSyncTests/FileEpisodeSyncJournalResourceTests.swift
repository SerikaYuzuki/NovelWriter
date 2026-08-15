import Foundation
import NovelSync
import NovelSyncLegacy
import NovelSyncTesting
import Testing

extension FileEpisodeSyncJournalTests {
    @Test("worst-case escaped conflict record remains within the journal cap and round-trips")
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
            localWorkingCopyID: SyncTestValues.localWorkingCopyID,
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

    @Test("maximum escaped conflict-resolution recovery remains within the journal cap")
    func worstCaseConflictResolutionRecovery() async throws {
        let root = temporaryRoot(named: "resolution-boundary")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let history = try makeConflictResolutionBoundaryHistory()
        let conflict = EpisodeConflict(
            base: nil,
            local: history.latestLocal,
            remote: history.latestRemote
        )
        let record = try EpisodeSyncJournalRecord(
            key: SyncTestValues.key,
            localWorkingCopyID: SyncTestValues.localWorkingCopyID,
            branchID: SyncTestValues.branchID,
            lastKnownRemoteHead: nil,
            localHead: history.latestLocal,
            pendingRevisions: [history.latestLocal],
            conflict: conflict,
            stagedConflictResolution: history.staged,
            conflictResolutionRecovery: EpisodeConflictResolutionRecovery(
                sourceLocalRevision: history.sourceLocal,
                sourceRemoteRevision: history.sourceRemote,
                chosenRevision: history.priorChoice,
                supersededChosenRevision: history.supersededChoice
            ),
            mode: .forcedFork
        )
        let encoded = try FileEpisodeSyncJournal.makeEncoder().encode(record)
        #expect(encoded.count < FileEpisodeSyncJournal.maximumRecordBytes)

        let journal = try FileEpisodeSyncJournal(rootURL: root)
        try await journal.save(record)
        #expect(try await journal.load(for: SyncTestValues.key) == record)
    }

    @Test("maximum escaped repeated-resolution relay remains within the journal cap")
    // The whole maximum-size state is intentionally assembled in one visible fixture.
    // swiftlint:disable:next function_body_length
    func worstCaseRepeatedResolutionRelay() async throws {
        let root = temporaryRoot(named: "repeated-resolution-relay-boundary")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let count = EpisodeRevision.maximumContentUTF8Bytes
        let remoteB = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666681",
            parents: [],
            content: String(repeating: "\0", count: count)
        )
        let remoteC = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666682",
            parents: [remoteB.revisionID],
            content: String(repeating: "\u{1}", count: count)
        )
        let localA = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666683",
            parents: [],
            content: String(repeating: "\u{2}", count: count),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        let packageAhead = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666684",
            parents: [localA.revisionID],
            content: String(repeating: "\u{3}", count: count),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        let firstChoice = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666685",
            parents: [remoteB.revisionID, packageAhead.revisionID],
            content: String(repeating: "\u{4}", count: count),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        let secondChoice = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666686",
            parents: [remoteC.revisionID, firstChoice.revisionID],
            content: String(repeating: "\u{5}", count: count),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        let relay = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666687",
            parents: [secondChoice.revisionID],
            content: String(repeating: "\u{6}", count: count),
            replica: SyncTestValues.replicaB,
            session: SyncEditSessionID()
        )
        let record = try EpisodeSyncJournalRecord(
            key: SyncTestValues.key,
            localWorkingCopyID: SyncTestValues.localWorkingCopyID,
            replicaID: SyncTestValues.replicaB,
            branchID: SyncTestValues.branchID,
            lastKnownRemoteHead: remoteC,
            localHead: relay,
            pendingRevisions: [localA, packageAhead, firstChoice, secondChoice, relay],
            stagedConflictResolution: secondChoice,
            conflictResolutionRecovery: EpisodeConflictResolutionRecovery(
                sourceLocalRevision: packageAhead,
                sourceRemoteRevision: remoteB,
                chosenRevision: secondChoice,
                supersededChosenRevision: firstChoice
            ),
            mode: .tracking
        )
        let encoded = try FileEpisodeSyncJournal.makeEncoder().encode(record)
        #expect(
            encoded.count < FileEpisodeSyncJournal.maximumRecordBytes,
            "encoded bytes: \(encoded.count)"
        )

        let journal = try FileEpisodeSyncJournal(rootURL: root)
        try await journal.save(record)
        #expect(try await journal.load(for: SyncTestValues.key) == record)
    }

    private struct ConflictResolutionBoundaryHistory {
        let sourceLocal: EpisodeRevision
        let sourceRemote: EpisodeRevision
        let priorChoice: EpisodeRevision
        let latestLocal: EpisodeRevision
        let latestRemote: EpisodeRevision
        let staged: EpisodeRevision
        let supersededChoice: EpisodeRevision
    }

    private func makeConflictResolutionBoundaryHistory() throws -> ConflictResolutionBoundaryHistory {
        let count = EpisodeRevision.maximumContentUTF8Bytes
        let sourceLocal = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666691",
            parents: [],
            content: String(repeating: "\0", count: count)
        )
        let sourceRemote = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666692",
            parents: [],
            content: String(repeating: "\u{1}", count: count)
        )
        let priorChoice = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666693",
            parents: [sourceRemote.revisionID, sourceLocal.revisionID],
            content: String(repeating: "\u{2}", count: count)
        )
        let latestLocal = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666694",
            parents: [sourceLocal.revisionID],
            content: String(repeating: "\u{3}", count: count)
        )
        let latestRemote = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666695",
            parents: [sourceRemote.revisionID],
            content: String(repeating: "\u{4}", count: count)
        )
        let staged = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666696",
            parents: [latestRemote.revisionID, latestLocal.revisionID],
            content: String(repeating: "\u{5}", count: count)
        )
        let supersededChoice = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666697",
            parents: [sourceRemote.revisionID, sourceLocal.revisionID],
            content: String(repeating: "\u{6}", count: count)
        )
        return ConflictResolutionBoundaryHistory(
            sourceLocal: sourceLocal,
            sourceRemote: sourceRemote,
            priorChoice: priorChoice,
            latestLocal: latestLocal,
            latestRemote: latestRemote,
            staged: staged,
            supersededChoice: supersededChoice
        )
    }
}
