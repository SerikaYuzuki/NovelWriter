import Foundation
import NovelCore
import NovelSync
import Testing

@Suite("Whole-work library projection")
struct SyncWorkLibraryTests {
    @Test("entry round-trips canonical exact head metadata")
    func exactHeadRoundTrip() throws {
        let revision = try WorkTestValues.revision(
            snapshot: WorkTestValues.snapshot(),
            id: "A1000000-0000-0000-0000-000000000001"
        )
        let entry = try SyncWorkLibraryEntry(head: revision)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(entry)
        let decoded = try JSONDecoder().decode(SyncWorkLibraryEntry.self, from: encoded)

        #expect(decoded == entry)
        try decoded.requireExactHead(revision)
        #expect(decoded.title == revision.snapshot.title)
        #expect(!decoded.isTitleTruncated)
    }

    @Test("one MiB title becomes a bounded linear-time display projection with exact digest")
    func hugeTitleProjectionIsBounded() throws {
        let fullTitle = String(repeating: "a", count: WorkSnapshot.maximumStringUTF8Bytes)
        let snapshot = try WorkTestValues.snapshot { $0.title = fullTitle }
        let revision = try WorkTestValues.revision(
            snapshot: snapshot,
            id: "A1000000-0000-0000-0000-000000000002"
        )
        let entry = try SyncWorkLibraryEntry(head: revision)

        #expect(entry.title.utf8.count == SyncWorkLibraryEntry.maximumDisplayTitleUTF8Bytes)
        #expect(entry.fullTitleUTF8ByteCount == fullTitle.utf8.count)
        #expect(entry.titleDigest == SyncContentDigest(content: fullTitle))
        #expect(entry.isTitleTruncated)
        try entry.requireExactHead(revision)
    }

    @Test("half-present head identity and a different immutable head are rejected")
    func malformedAndDifferentHeadsAreRejected() throws {
        let descriptor = try SyncWorkDescriptor(
            sourceDocumentID: WorkTestValues.documentID,
            structureDigest: SyncWorkStructureDigest(
                chapters: WorkTestValues.fullDocument().chapters
            ),
            title: "作品"
        )
        #expect(throws: SyncWorkLibraryError.inconsistentHeadIdentity) {
            try SyncWorkLibraryEntry(
                workID: descriptor.workID,
                sourceDocumentID: descriptor.sourceDocumentID,
                structureDigest: descriptor.structureDigest,
                title: descriptor.title,
                titleDigest: SyncContentDigest(content: descriptor.title),
                fullTitleUTF8ByteCount: descriptor.title.utf8.count,
                headRevisionID: SyncRevisionID(),
                headSnapshotDigest: nil,
                headSnapshotByteCount: nil,
                headClientCreatedAt: nil
            )
        }

        let first = try WorkTestValues.revision(
            snapshot: WorkTestValues.snapshot(),
            id: "A1000000-0000-0000-0000-000000000003"
        )
        let second = try WorkTestValues.revision(
            snapshot: WorkTestValues.snapshot { $0.title = "改題" },
            id: "A1000000-0000-0000-0000-000000000004"
        )
        let entry = try SyncWorkLibraryEntry(head: first)
        #expect(throws: SyncWorkLibraryError.snapshotMismatch) {
            try entry.requireExactHead(second)
        }
    }

    @Test("Note catalog nil-head matches local package without revision snapshot identity")
    func noteCatalogMatchesLocalPackageWithoutRevisionHead() throws {
        let document = WorkTestValues.fullDocument()
        let snapshot = try WorkSnapshot(document: document)
        let records = try NoteSyncProjection.records(
            workID: WorkTestValues.workID,
            snapshot: snapshot
        )
        let workRecord = try #require(records.first { $0.key.kind == .work })
        let entry = try SyncWorkLibraryEntry(noteWork: workRecord)
        let localStructure = try SyncWorkStructureDigest(chapters: document.chapters)
        let unusedDigest = SyncContentDigest(content: "unused-snapshot")
        let titleDigest = SyncContentDigest(content: document.title)

        #expect(!entry.hasWorkRevisionHead)
        #expect(entry.structureDigest != localStructure)
        #expect(
            entry.matchesInstalledPackage(
                documentID: document.id,
                structureDigest: localStructure,
                snapshotDigest: unusedDigest,
                snapshotByteCount: 1,
                titleDigest: titleDigest,
                fullTitleUTF8ByteCount: document.title.utf8.count
            )
        )
        #expect(
            !entry.matchesInstalledPackage(
                documentID: UUID(),
                structureDigest: localStructure,
                snapshotDigest: unusedDigest,
                snapshotByteCount: 1,
                titleDigest: titleDigest,
                fullTitleUTF8ByteCount: document.title.utf8.count
            )
        )

        let revision = try WorkTestValues.revision(
            snapshot: snapshot,
            id: "A1000000-0000-0000-0000-00000000000A"
        )
        try entry.requireCatalogIdentity(revision)
    }
}
