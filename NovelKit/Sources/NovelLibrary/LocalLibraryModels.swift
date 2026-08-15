import Foundation
import NovelCore
import NovelSync

/// Durable local-library errors shared by the macOS and iOS registry adapters.
public enum LibraryRegistryError: Error, Equatable, Sendable {
    case unsafeRoot
    case invalidRegistry
    case duplicateWork
    case missingWork
    case invalidTransition
    case packageMismatch
}

/// State machine for a local package and its optional remote acknowledgement.
///
/// The app adapters own filesystem roots and UI policy; this value owns only the
/// persisted state and validation rules shared by both platforms.
public enum LibraryRecordState: String, Codable, Hashable, Sendable {
    /// Work identity is reserved before package installation completes.
    case reservedForPublish
    /// Package readback succeeded; initial remote publication is unconfirmed.
    case publishPending
    /// The exact remote entry was acknowledged for this package.
    case synced
    /// An exact remote download intent is durable and resumable.
    case remoteOpenPending
    /// The package is readable but must not adopt remote changes automatically.
    case needsReview
    /// A package is retained while account scope is re-established.
    case accountQuarantined
    /// A legacy package was explicitly preserved during migration.
    case legacyPreserved
}

/// Readback attestation shared by local-library registry adapters.
public struct LocalPackageAttestation: Codable, Hashable, Sendable {
    public let documentID: UUID
    public let structureDigest: SyncWorkStructureDigest
    public let snapshotDigest: SyncContentDigest
    public let snapshotByteCount: Int
    public let titleProjection: String
    public let titleDigest: SyncContentDigest
    public let fullTitleUTF8ByteCount: Int
    public let updatedAt: Date

    public init(document: NovelDocument, updatedAt: Date) throws {
        let snapshot = try WorkSnapshot(document: document)
        let canonical = try WorkCanonicalJSON.encodeSnapshot(snapshot)
        documentID = document.id
        structureDigest = try SyncWorkStructureDigest(chapters: document.chapters)
        // Digest input is the already-validated canonical UTF-8 byte sequence.
        // swiftlint:disable:next optional_data_string_conversion
        snapshotDigest = SyncContentDigest(content: String(decoding: canonical, as: UTF8.self))
        snapshotByteCount = canonical.count
        titleProjection = SyncWorkLibraryEntry.displayTitleProjection(document.title)
        titleDigest = SyncContentDigest(content: document.title)
        fullTitleUTF8ByteCount = document.title.utf8.count
        self.updatedAt = updatedAt
        try validate()
    }

    public func validate() throws {
        guard snapshotByteCount >= 0,
              snapshotByteCount <= WorkSnapshot.maximumCanonicalByteCount,
              titleProjection.utf8.count <= SyncWorkLibraryEntry.maximumDisplayTitleUTF8Bytes,
              fullTitleUTF8ByteCount >= titleProjection.utf8.count,
              fullTitleUTF8ByteCount <= WorkSnapshot.maximumStringUTF8Bytes,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRegistryError.invalidRegistry
        }
    }

    public func matches(_ remote: SyncWorkLibraryEntry) -> Bool {
        remote.matchesInstalledPackage(
            documentID: documentID,
            structureDigest: structureDigest,
            snapshotDigest: snapshotDigest,
            snapshotByteCount: snapshotByteCount,
            titleDigest: titleDigest,
            fullTitleUTF8ByteCount: fullTitleUTF8ByteCount
        )
    }
}

/// Durable registry record shared by both platform-specific filesystem stores.
public struct LibraryRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: SyncWorkID {
        workID
    }

    public let workID: SyncWorkID
    public let expectedDocumentID: UUID
    public var state: LibraryRecordState
    public var package: LocalPackageAttestation?
    /// Exact acknowledgement; it never means “currently present in catalog”.
    public var acknowledgedRemote: SyncWorkLibraryEntry?
    /// Exact catalog entry to resume for a remote open.
    public var pendingRemote: SyncWorkLibraryEntry?

    public init(
        workID: SyncWorkID,
        expectedDocumentID: UUID,
        state: LibraryRecordState,
        package: LocalPackageAttestation?,
        acknowledgedRemote: SyncWorkLibraryEntry?,
        pendingRemote: SyncWorkLibraryEntry?
    ) {
        self.workID = workID
        self.expectedDocumentID = expectedDocumentID
        self.state = state
        self.package = package
        self.acknowledgedRemote = acknowledgedRemote
        self.pendingRemote = pendingRemote
    }

    public func validate() throws {
        try package?.validate()
        try acknowledgedRemote?.validate()
        try pendingRemote?.validate()
        guard package?.documentID == nil || package?.documentID == expectedDocumentID else {
            throw LibraryRegistryError.invalidRegistry
        }
        try validateState()
    }

    private func validateState() throws {
        switch state {
        case .reservedForPublish, .publishPending:
            guard package != nil, acknowledgedRemote == nil, pendingRemote == nil else {
                throw LibraryRegistryError.invalidRegistry
            }
        case .synced:
            guard let package, let acknowledgedRemote,
                  pendingRemote == nil,
                  acknowledgedRemote.workID == workID,
                  package.matches(acknowledgedRemote) else {
                throw LibraryRegistryError.invalidRegistry
            }
        case .remoteOpenPending:
            guard acknowledgedRemote == nil,
                  let pendingRemote,
                  pendingRemote.workID == workID,
                  pendingRemote.sourceDocumentID == expectedDocumentID,
                  package == nil || package?.matches(pendingRemote) == true else {
                throw LibraryRegistryError.invalidRegistry
            }
        case .needsReview, .legacyPreserved:
            guard package != nil, acknowledgedRemote == nil, pendingRemote == nil else {
                throw LibraryRegistryError.invalidRegistry
            }
        case .accountQuarantined:
            guard package != nil,
                  acknowledgedRemote == nil,
                  pendingRemote == nil || (
                      pendingRemote?.workID == workID
                          && pendingRemote?.sourceDocumentID == expectedDocumentID
                          && pendingRemote.map { package?.matches($0) == true } == true
                  ) else {
                throw LibraryRegistryError.invalidRegistry
            }
        }
    }
}

/// Inventory result returned by a platform-specific registry adapter.
public struct LibraryInventory: Sendable {
    public let records: [LibraryRecord]
    public let unreadableWorkIDs: Set<SyncWorkID>
    public let unregisteredPackageWorkIDs: Set<SyncWorkID>

    public init(
        records: [LibraryRecord],
        unreadableWorkIDs: Set<SyncWorkID>,
        unregisteredPackageWorkIDs: Set<SyncWorkID>
    ) {
        self.records = records
        self.unreadableWorkIDs = unreadableWorkIDs
        self.unregisteredPackageWorkIDs = unregisteredPackageWorkIDs
    }
}
