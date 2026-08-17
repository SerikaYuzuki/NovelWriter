import Foundation
import NovelSyncV2

/// Evidence produced outside the migration stage by the operator/export
/// authority.  The stage report is deliberately not an authority: it is only
/// an untrusted projection that must match this record exactly.
public struct MigrationTrustedProvenanceAuthority: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let authorityID: String
    public let sourceSQLiteSHA256: String
    public let sourceArchiveManifestSHA256: String
    public let classificationLedgerSHA256: String
    public let entries: [MigrationTrustedProvenanceEntry]

    public init(
        formatVersion: Int = 1,
        authorityID: String,
        sourceSQLiteSHA256: String,
        sourceArchiveManifestSHA256: String,
        classificationLedgerSHA256: String,
        entries: [MigrationTrustedProvenanceEntry]
    ) {
        self.formatVersion = formatVersion
        self.authorityID = authorityID
        self.sourceSQLiteSHA256 = sourceSQLiteSHA256
        self.sourceArchiveManifestSHA256 = sourceArchiveManifestSHA256
        self.classificationLedgerSHA256 = classificationLedgerSHA256
        self.entries = entries
    }
}

public struct MigrationTrustedProvenanceEntry: Codable, Equatable, Sendable {
    public let workID: UUID
    public let disposition: String
    public let packageSHA256: String
    public let sourceSQLiteSHA256: String
    public let sourceArchiveManifestSHA256: String
    public let classificationLedgerSHA256: String
    public let snapshotID: String?
    public let projectionDigest: String?
    public let inventoryEvidenceSHA256: String

    public init(
        workID: UUID,
        disposition: String,
        packageSHA256: String,
        sourceSQLiteSHA256: String,
        sourceArchiveManifestSHA256: String,
        classificationLedgerSHA256: String,
        snapshotID: String?,
        projectionDigest: String?,
        inventoryEvidenceSHA256: String
    ) {
        self.workID = workID
        self.disposition = disposition
        self.packageSHA256 = packageSHA256
        self.sourceSQLiteSHA256 = sourceSQLiteSHA256
        self.sourceArchiveManifestSHA256 = sourceArchiveManifestSHA256
        self.classificationLedgerSHA256 = classificationLedgerSHA256
        self.snapshotID = snapshotID
        self.projectionDigest = projectionDigest
        self.inventoryEvidenceSHA256 = inventoryEvidenceSHA256
    }
}

func migrationInventoryEvidenceDigest(_ inventory: SourceInventory) throws -> String {
    guard var object = try JSONSerialization.jsonObject(with: inventory.registryEvidence) as? [String: Any] else {
        throw TrustedProvenanceBuilderError.invalidInventoryEvidence
    }
    object.removeValue(forKey: "sourcePath")
    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return SHA256Digest.hex(canonical)
}
