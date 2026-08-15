import Foundation
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync work matching")
struct AppleDeviceSyncWorkMatcherTests {
    @Test("an exact work-create retry is idempotent but a collision stays rejected")
    func exactWorkCreateRetryIsIdempotent() throws {
        let structure = try SyncWorkStructureDigest(
            validating: String(repeating: "c", count: 64)
        )
        let sourceDocumentID = try #require(
            UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")
        )
        let descriptor = SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: sourceDocumentID,
            structureDigest: structure,
            title: "再開対象"
        )

        try CloudKitWorkCreationMatcher.requireIdempotentRetry(
            existing: descriptor,
            requested: descriptor
        )
        let collision = SyncWorkDescriptor(
            workID: descriptor.workID,
            sourceDocumentID: sourceDocumentID,
            structureDigest: structure,
            title: "異なる作品名"
        )
        #expect(throws: SyncCatalogError.duplicateWorkID) {
            try CloudKitWorkCreationMatcher.requireIdempotentRetry(
                existing: descriptor,
                requested: collision
            )
        }
    }

    @Test("structure is authoritative while source document ID only orders candidates")
    func structureSafeCandidates() throws {
        let fixture = try makeMatcherFixture()
        let candidates = AppleDeviceSyncWorkMatcher.candidates(
            from: [fixture.staleStructure, fixture.importedCopy, fixture.hintMatch],
            sourceDocumentIDHint: fixture.sourceHint,
            structureDigest: fixture.expectedStructure
        )
        #expect(candidates.count == 2)
        #expect(candidates.first?.workID == fixture.hintMatch.workID)
        #expect(candidates.contains(where: { $0.workID == fixture.importedCopy.workID }))
        #expect(!candidates.contains(where: { $0.workID == fixture.staleStructure.workID }))
    }

    @Test("binding requires the selected work and source continuity")
    func bindingRequiresExactSelectedWork() throws {
        let fixture = try makeMatcherFixture()
        let candidates = [fixture.hintMatch, fixture.importedCopy]

        #expect(
            try AppleDeviceSyncWorkMatcher.requireDescriptor(
                workID: fixture.importedCopy.workID,
                structureDigest: fixture.expectedStructure,
                in: candidates
            ) == fixture.importedCopy
        )
        #expect(throws: AppleDeviceSyncServicesError.structureMismatch) {
            try AppleDeviceSyncWorkMatcher.requireDescriptor(
                workID: fixture.staleStructure.workID,
                structureDigest: fixture.expectedStructure,
                in: [fixture.staleStructure]
            )
        }
        #expect(throws: AppleDeviceSyncServicesError.remoteWorkNotFound) {
            try AppleDeviceSyncWorkMatcher.requireDescriptor(
                workID: SyncWorkID(),
                structureDigest: fixture.expectedStructure,
                in: candidates
            )
        }

        // binding後は章／話の追加でwhole-work digestが変わっても継続する。
        #expect(
            try AppleDeviceSyncWorkMatcher.requireBoundDescriptor(
                workID: fixture.staleStructure.workID,
                localSourceDocumentID: fixture.sourceHint,
                in: [fixture.staleStructure]
            ) == fixture.staleStructure
        )
        #expect(throws: AppleDeviceSyncServicesError.sourceDocumentMismatch) {
            try AppleDeviceSyncWorkMatcher.requireBoundDescriptor(
                workID: fixture.importedCopy.workID,
                localSourceDocumentID: fixture.sourceHint,
                in: [fixture.importedCopy]
            )
        }
    }
}

private struct WorkMatcherFixture {
    let expectedStructure: SyncWorkStructureDigest
    let sourceHint: UUID
    let hintMatch: SyncWorkDescriptor
    let importedCopy: SyncWorkDescriptor
    let staleStructure: SyncWorkDescriptor
}

private func makeMatcherFixture() throws -> WorkMatcherFixture {
    let expected = try SyncWorkStructureDigest(validating: String(repeating: "a", count: 64))
    let other = try SyncWorkStructureDigest(validating: String(repeating: "b", count: 64))
    let sourceHint = try #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
    let differentSource = try #require(UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"))
    return WorkMatcherFixture(
        expectedStructure: expected,
        sourceHint: sourceHint,
        hintMatch: SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: sourceHint,
            structureDigest: expected,
            title: "hint match"
        ),
        importedCopy: SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: differentSource,
            structureDigest: expected,
            title: "same structure"
        ),
        staleStructure: SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: sourceHint,
            structureDigest: other,
            title: "stale package"
        )
    )
}
