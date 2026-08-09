import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex deployment manifest verification must only compile in FUMINIWAExperimental")
#endif

enum CodexDeploymentManifestError: String, Error, Sendable, Equatable {
    case invalidRoot = "invalid_root"
    case invalidPath = "invalid_path"
    case symbolicLink = "symlink"
    case unsupportedEntry = "unsupported_entry"
    case hardLink = "hardlink"
    case invalidMode = "invalid_mode"
    case resourceLimit = "resource_limit"
    case treeChanged = "tree_changed"
    case invalidDigest = "invalid_digest"
    case digestMismatch = "digest_mismatch"
}

struct CodexDeploymentManifestRecord: Sendable, Equatable {
    enum Kind: UInt8, Sendable, Equatable {
        case directory = 0x01
        case file = 0x02
    }

    let kind: Kind
    let path: String
    let mode: UInt16
    let size: UInt64?
    let sha256: String?
}

struct CodexDeploymentManifest: Sendable, Equatable {
    let version: UInt32
    let rootDigest: String
    let canonicalBytes: Data
    let records: [CodexDeploymentManifestRecord]
}

enum CodexDeploymentManifestLimits {
    static let version: UInt32 = 1
    static let selfManifestPath = ".fuminiwa-codex-deployment-manifest-v1.bin"
    static let maximumEntryCount = 100_000
    static let maximumComponentBytes = 255
    static let maximumRelativePathBytes = 4096
    static let maximumFileBytes: UInt64 = 512 * 1024 * 1024
    static let maximumTotalFileBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maximumCanonicalManifestBytes = 64 * 1024 * 1024
}

struct CodexDeploymentManifestTestingHooks: Sendable {
    let afterFileContentRead: (@Sendable (String) -> Void)?
    let afterDirectoryTraversal: (@Sendable (String) -> Void)?

    init(
        afterFileContentRead: (@Sendable (String) -> Void)? = nil,
        afterDirectoryTraversal: (@Sendable (String) -> Void)? = nil
    ) {
        self.afterFileContentRead = afterFileContentRead
        self.afterDirectoryTraversal = afterDirectoryTraversal
    }

    static let none = Self()
}

enum CodexDeploymentManifestVerifier {
    static func create(
        rootPath: String,
        testingHooks: CodexDeploymentManifestTestingHooks = .none
    ) throws -> CodexDeploymentManifest {
        let entries = try CodexDeploymentManifestBuilder(
            rootPath: rootPath,
            testingHooks: testingHooks
        ).build()
        return try CodexDeploymentManifestCanonical.makeManifest(entries: entries)
    }

    static func verify(
        rootPath: String,
        expectedRootDigest: String,
        testingHooks: CodexDeploymentManifestTestingHooks = .none
    ) throws -> CodexDeploymentManifest {
        guard let expectedDigest = decodeLowercaseSHA256(expectedRootDigest) else {
            throw CodexDeploymentManifestError.invalidDigest
        }
        let manifest = try create(rootPath: rootPath, testingHooks: testingHooks)
        guard let actualDigest = decodeLowercaseSHA256(manifest.rootDigest) else {
            throw CodexDeploymentManifestError.invalidDigest
        }
        guard constantTimeEqual(actualDigest, expectedDigest) else {
            throw CodexDeploymentManifestError.digestMismatch
        }
        return manifest
    }

    static func decodeCanonicalRelativePath(_ bytes: Data) throws -> String {
        guard !bytes.isEmpty else {
            throw CodexDeploymentManifestError.invalidPath
        }
        guard bytes.count <= CodexDeploymentManifestLimits.maximumRelativePathBytes else {
            throw CodexDeploymentManifestError.resourceLimit
        }

        var components: [String] = []
        var componentStart = bytes.startIndex
        var index = bytes.startIndex
        while true {
            if index == bytes.endIndex || bytes[index] == 0x2F {
                let component = Data(bytes[componentStart ..< index])
                try components.append(decodeCanonicalComponent(component))
                if index == bytes.endIndex {
                    break
                }
                componentStart = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        return components.joined(separator: "/")
    }

    static func decodeCanonicalComponent(_ bytes: Data) throws -> String {
        let hasValidLength = !bytes.isEmpty
            && bytes.count <= CodexDeploymentManifestLimits.maximumComponentBytes
        guard hasValidLength else {
            throw CodexDeploymentManifestError.invalidPath
        }
        guard let component = String(data: bytes, encoding: .utf8) else {
            throw CodexDeploymentManifestError.invalidPath
        }
        let isCanonical = Data(component.utf8) == bytes
            && component != "."
            && component != ".."
            && !component.utf8.contains(0)
            && !component.contains("/")
        guard isCanonical else {
            throw CodexDeploymentManifestError.invalidPath
        }
        return component
    }

    private static func decodeLowercaseSHA256(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count == 64 else { return nil }
        var digest = Data(capacity: 32)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let high = lowercaseHexNibble(bytes[offset])
            let low = lowercaseHexNibble(bytes[offset + 1])
            guard let high, let low else {
                return nil
            }
            digest.append(high << 4 | low)
        }
        return digest
    }

    private static func lowercaseHexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39:
            byte - 0x30
        case 0x61 ... 0x66:
            byte - 0x61 + 10
        default:
            nil
        }
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (leftByte, rightByte) in zip(left, right) {
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }
}
