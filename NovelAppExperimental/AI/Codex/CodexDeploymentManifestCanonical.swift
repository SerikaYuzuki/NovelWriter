import CryptoKit
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex deployment manifest verification must only compile in FUMINIWAExperimental")
#endif

struct CodexDeploymentManifestEntry {
    let kind: CodexDeploymentManifestRecord.Kind
    let path: String
    let pathBytes: Data
    let mode: UInt16
    let size: UInt64?
    let digest: Data?
}

enum CodexDeploymentManifestCanonical {
    private static let magic = Data("FUMINIWA-CODEX-DEPLOYMENT-MANIFEST\0".utf8)

    static func makeManifest(
        entries: [CodexDeploymentManifestEntry]
    ) throws -> CodexDeploymentManifest {
        guard entries.count <= CodexDeploymentManifestLimits.maximumEntryCount else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        let byteCount = try checkedManifestByteCount(for: entries)
        let sortedEntries = entries.sorted {
            $0.pathBytes.lexicographicallyPrecedes($1.pathBytes)
        }
        var canonicalBytes = Data()
        canonicalBytes.reserveCapacity(byteCount)
        canonicalBytes.append(magic)
        canonicalBytes.appendBigEndian(CodexDeploymentManifestLimits.version)
        canonicalBytes.appendBigEndian(UInt64(sortedEntries.count))
        for entry in sortedEntries {
            try canonicalBytes.append(canonicalRecord(entry))
            guard canonicalBytes.count <= CodexDeploymentManifestLimits.maximumCanonicalManifestBytes else {
                throw CodexDeploymentManifestError.resourceLimit
            }
        }

        let rootDigest = Data(SHA256.hash(data: canonicalBytes)).lowercaseHex
        let records = sortedEntries.map { entry in
            CodexDeploymentManifestRecord(
                kind: entry.kind,
                path: entry.path,
                mode: entry.mode,
                size: entry.size,
                sha256: entry.digest?.lowercaseHex
            )
        }
        return CodexDeploymentManifest(
            version: CodexDeploymentManifestLimits.version,
            rootDigest: rootDigest,
            canonicalBytes: canonicalBytes,
            records: records
        )
    }

    private static func canonicalRecord(_ entry: CodexDeploymentManifestEntry) throws -> Data {
        var payload = Data()
        payload.append(entry.kind.rawValue)
        guard let pathLength = UInt32(exactly: entry.pathBytes.count) else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        payload.appendBigEndian(pathLength)
        payload.append(entry.pathBytes)
        payload.appendBigEndian(entry.mode)

        if entry.kind == .file {
            guard let size = entry.size, let digest = entry.digest, digest.count == 32 else {
                throw CodexDeploymentManifestError.treeChanged
            }
            payload.appendBigEndian(size)
            payload.append(digest)
        }

        var record = Data()
        record.appendBigEndian(UInt64(payload.count))
        record.append(payload)
        return record
    }

    static func checkedManifestByteCount(
        for entries: [CodexDeploymentManifestEntry]
    ) throws -> Int {
        var total = magic.count + 4 + 8
        for entry in entries {
            let recordByteCount = try checkedRecordByteCount(
                pathByteCount: entry.pathBytes.count,
                kind: entry.kind
            )
            total = try checkedManifestByteCount(
                current: total,
                addingRecord: recordByteCount
            )
        }
        return total
    }

    static func checkedRecordByteCount(
        pathByteCount: Int,
        kind: CodexDeploymentManifestRecord.Kind
    ) throws -> Int {
        guard pathByteCount >= 0 else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        let fixedFields = 8 + 1 + 4 + 2 + (kind == .file ? 8 + 32 : 0)
        let total = fixedFields.addingReportingOverflow(pathByteCount)
        guard !total.overflow else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        return total.partialValue
    }

    static func checkedManifestByteCount(recordByteCounts: [Int]) throws -> Int {
        var total = magic.count + 4 + 8
        for record in recordByteCounts {
            total = try checkedManifestByteCount(current: total, addingRecord: record)
        }
        return total
    }

    private static func checkedManifestByteCount(
        current: Int,
        addingRecord record: Int
    ) throws -> Int {
        guard record >= 0 else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        let addition = current.addingReportingOverflow(record)
        let isWithinLimit = !addition.overflow
            && addition.partialValue
            <= CodexDeploymentManifestLimits.maximumCanonicalManifestBytes
        guard isWithinLimit else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        return addition.partialValue
    }
}

extension Data {
    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendBigEndian(_ value: UInt16) {
        appendFixedWidth(value.bigEndian)
    }

    mutating func appendBigEndian(_ value: UInt32) {
        appendFixedWidth(value.bigEndian)
    }

    mutating func appendBigEndian(_ value: UInt64) {
        appendFixedWidth(value.bigEndian)
    }

    private mutating func appendFixedWidth(_ value: some Any) {
        var mutableValue = value
        Swift.withUnsafeBytes(of: &mutableValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
