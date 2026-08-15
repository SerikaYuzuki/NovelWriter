import Foundation
import NovelCore
import NovelLibrary
import NovelSync
import Testing

struct LocalLibraryModelsTests {
    @Test("共有stateはMac/iOSの全永続状態をCodableで往復する")
    func allStatesRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in [
            LibraryRecordState.reservedForPublish,
            .publishPending,
            .synced,
            .remoteOpenPending,
            .needsReview,
            .accountQuarantined,
            .legacyPreserved
        ] {
            let data = try encoder.encode(state)
            #expect(try decoder.decode(LibraryRecordState.self, from: data) == state)
        }
    }

    @Test("package attestationは共有モデルとしてrecord検証へ使える")
    func recordValidationUsesSharedAttestation() throws {
        let document = NovelDocument.newDocument()
        let attestation = try LocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSinceReferenceDate: 123)
        )
        let record = LibraryRecord(
            workID: SyncWorkID(),
            expectedDocumentID: document.id,
            state: .publishPending,
            package: attestation,
            acknowledgedRemote: nil,
            pendingRemote: nil
        )

        try record.validate()
    }
}
