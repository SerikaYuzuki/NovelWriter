import Foundation
import NovelCore
import NovelStorage
import NovelSync
import Testing

@Suite("Device Sync local library store", .serialized)
struct DeviceSyncLocalLibraryStoreTests {
    @Test("publish staging attestation survives install-confirm kill window")
    func publishInstallKillWindowRepairsWithoutReplacingPackage() async throws {
        let fixture = try LocalLibraryFixture()
        defer { fixture.remove() }
        let repository = NovelpkgRepository()
        let document = NovelDocument.newDocument(title: "地下鉄で作った作品")
        let workID = SyncWorkID()

        let attestation = try DeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        try await fixture.store.reserveForPublish(
            workID: workID,
            expectedPackage: attestation
        )
        let staging = try await fixture.store.stagingPackageURL(for: workID)
        try await repository.save(document, to: staging)
        try await fixture.store.attestPublishStaging(workID: workID, package: attestation)

        let installed = try await fixture.store.installStagingPackage(staging, for: workID)
        #expect(try await repository.validatePortablePackage(at: installed) == document)

        // Process death here: a newly constructed store sees the exact reserved attestation.
        let relaunched = try fixture.makeStore()
        let pending = try #require(try await relaunched.record(for: workID))
        #expect(pending.state == .reservedForPublish)
        #expect(pending.package == attestation)
        try await relaunched.confirmPublishPackage(workID: workID, package: attestation)

        let repaired = try #require(try await relaunched.record(for: workID))
        #expect(repaired.state == .publishPending)
        #expect(repaired.package == attestation)
        #expect(try await repository.validatePortablePackage(at: installed) == document)
    }

    @Test("atomic install refuses an existing final package")
    func installNeverOverwritesExistingFinal() async throws {
        let fixture = try LocalLibraryFixture()
        defer { fixture.remove() }
        let repository = NovelpkgRepository()
        let workID = SyncWorkID()
        let first = NovelDocument.newDocument(title: "先にある作品")
        let second = NovelDocument.newDocument(title: "上書きしてはいけない作品")

        let final = try await fixture.store.packageURL(for: workID)
        try await repository.save(first, to: final)
        let staging = try await fixture.store.stagingPackageURL(for: workID)
        try await repository.save(second, to: staging)

        do {
            _ = try await fixture.store.installStagingPackage(staging, for: workID)
            Issue.record("existing final package was replaced")
        } catch {
            #expect(try await repository.validatePortablePackage(at: final) == first)
            #expect(try await repository.validatePortablePackage(at: staging) == second)
        }
    }

    @Test("needs-review survives later package saves")
    func mutationDoesNotEraseNeedsReview() async throws {
        let fixture = try LocalLibraryFixture()
        defer { fixture.remove() }
        let repository = NovelpkgRepository()
        var document = NovelDocument.newDocument(title: "統合待ち")
        let workID = SyncWorkID()
        try await installPending(
            document,
            workID: workID,
            fixture: fixture,
            repository: repository
        )
        try await fixture.store.markNeedsReview(workID: workID)

        document.title = "統合待ちのまま編集"
        let final = try await fixture.store.packageURL(for: workID)
        try await repository.save(document, to: final)
        let changed = try DeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try await fixture.store.recordPackageMutation(workID: workID, package: changed)

        let record = try #require(try await fixture.store.record(for: workID))
        #expect(record.state == .needsReview)
        #expect(record.package == changed)
        #expect(record.acknowledgedRemote == nil)
    }

    @Test("one corrupt record is isolated and orphan packages remain visible")
    func corruptRecordDoesNotEraseOtherWorks() async throws {
        let fixture = try LocalLibraryFixture()
        defer { fixture.remove() }
        let repository = NovelpkgRepository()
        let goodWorkID = SyncWorkID()
        let orphanWorkID = SyncWorkID()
        try await installPending(
            NovelDocument.newDocument(title: "正常"),
            workID: goodWorkID,
            fixture: fixture,
            repository: repository
        )
        let orphanURL = try await fixture.store.packageURL(for: orphanWorkID)
        try await repository.save(NovelDocument.newDocument(title: "孤立"), to: orphanURL)

        let corruptID = SyncWorkID()
        let corruptURL = fixture.registryRoot.appendingPathComponent(
            "\(corruptID.rawValue.uuidString).json"
        )
        try Data("not-json".utf8).write(to: corruptURL)

        let inventory = try await fixture.store.inventory()
        #expect(inventory.records.map(\.workID).contains(goodWorkID))
        #expect(inventory.unreadableWorkIDs.contains(corruptID))
        #expect(inventory.unregisteredPackageWorkIDs.contains(orphanWorkID))
    }

    @Test("legacy reservation without an expected package is quarantined")
    func legacyReservationWithoutExpectedPackageIsRejected() {
        let record = DeviceSyncLocalLibraryRecord(
            workID: SyncWorkID(),
            expectedDocumentID: UUID(),
            state: .reservedForPublish,
            package: nil,
            acknowledgedRemote: nil,
            pendingRemote: nil
        )

        #expect(throws: DeviceSyncLocalLibraryError.self) {
            try record.validate()
        }
    }

    private func installPending(
        _ document: NovelDocument,
        workID: SyncWorkID,
        fixture: LocalLibraryFixture,
        repository: NovelpkgRepository
    ) async throws {
        let attestation = try DeviceSyncLocalPackageAttestation(
            document: document,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try await fixture.store.reserveForPublish(
            workID: workID,
            expectedPackage: attestation
        )
        let staging = try await fixture.store.stagingPackageURL(for: workID)
        try await repository.save(document, to: staging)
        try await fixture.store.attestPublishStaging(workID: workID, package: attestation)
        _ = try await fixture.store.installStagingPackage(staging, for: workID)
        try await fixture.store.confirmPublishPackage(workID: workID, package: attestation)
    }
}

private struct LocalLibraryFixture {
    let base: URL
    let registryRoot: URL
    let workingRootURL: URL
    let workingRoot: DeviceSyncPrivateWorkingCopyRoot
    let store: DeviceSyncLocalLibraryStore

    init() throws {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DeviceSyncLocalLibraryError.unsafeRoot
        }
        base = applicationSupport
            .appendingPathComponent("FUMINIWATests", isDirectory: true)
            .appendingPathComponent(
                "fuminiwa-local-library-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        registryRoot = base.appendingPathComponent("registry", isDirectory: true)
        workingRootURL = base.appendingPathComponent("SyncWorkingCopies-v2", isDirectory: true)
        workingRoot = try DeviceSyncPrivateWorkingCopyRoot.prepare(
            workingRootURL,
            fileManager: .default
        )
        store = try DeviceSyncLocalLibraryStore(
            registryRootURL: registryRoot,
            trustedAncestorURL: base,
            workingCopyRoot: workingRoot
        )
    }

    func makeStore() throws -> DeviceSyncLocalLibraryStore {
        let root = try DeviceSyncPrivateWorkingCopyRoot.prepare(
            workingRootURL,
            fileManager: .default
        )
        return try DeviceSyncLocalLibraryStore(
            registryRootURL: registryRoot,
            trustedAncestorURL: base,
            workingCopyRoot: root
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
