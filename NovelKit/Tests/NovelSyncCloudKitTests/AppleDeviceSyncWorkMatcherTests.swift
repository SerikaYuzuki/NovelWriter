import Foundation
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync work matching")
struct AppleDeviceSyncWorkMatcherTests {
    @Test("structure is authoritative while source document ID only orders candidates")
    func structureSafeCandidates() throws {
        let expectedStructure = try SyncWorkStructureDigest(
            validating: String(repeating: "a", count: 64)
        )
        let otherStructure = try SyncWorkStructureDigest(
            validating: String(repeating: "b", count: 64)
        )
        let sourceHint = try #require(
            UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        )
        let differentSource = try #require(
            UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")
        )
        let hintMatch = SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: sourceHint,
            structureDigest: expectedStructure,
            title: "hint match"
        )
        let importedCopy = SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: differentSource,
            structureDigest: expectedStructure,
            title: "same structure"
        )
        let staleStructure = SyncWorkDescriptor(
            workID: SyncWorkID(),
            sourceDocumentID: sourceHint,
            structureDigest: otherStructure,
            title: "stale package"
        )

        let candidates = AppleDeviceSyncWorkMatcher.candidates(
            from: [staleStructure, importedCopy, hintMatch],
            sourceDocumentIDHint: sourceHint,
            structureDigest: expectedStructure
        )
        #expect(candidates.count == 2)
        #expect(candidates.first?.workID == hintMatch.workID)
        #expect(candidates.contains(where: { $0.workID == importedCopy.workID }))
        #expect(!candidates.contains(where: { $0.workID == staleStructure.workID }))

        #expect(
            try AppleDeviceSyncWorkMatcher.requireDescriptor(
                workID: importedCopy.workID,
                structureDigest: expectedStructure,
                in: candidates
            ) == importedCopy
        )
        #expect(throws: AppleDeviceSyncServicesError.structureMismatch) {
            try AppleDeviceSyncWorkMatcher.requireDescriptor(
                workID: staleStructure.workID,
                structureDigest: expectedStructure,
                in: [staleStructure]
            )
        }
        #expect(throws: AppleDeviceSyncServicesError.remoteWorkNotFound) {
            try AppleDeviceSyncWorkMatcher.requireDescriptor(
                workID: SyncWorkID(),
                structureDigest: expectedStructure,
                in: candidates
            )
        }

        // binding後は章／話の追加でwhole-work digestが変わっても継続する。
        #expect(
            try AppleDeviceSyncWorkMatcher.requireBoundDescriptor(
                workID: staleStructure.workID,
                localSourceDocumentID: sourceHint,
                in: [staleStructure]
            ) == staleStructure
        )
        #expect(throws: AppleDeviceSyncServicesError.sourceDocumentMismatch) {
            try AppleDeviceSyncWorkMatcher.requireBoundDescriptor(
                workID: importedCopy.workID,
                localSourceDocumentID: sourceHint,
                in: [importedCopy]
            )
        }
    }
}
