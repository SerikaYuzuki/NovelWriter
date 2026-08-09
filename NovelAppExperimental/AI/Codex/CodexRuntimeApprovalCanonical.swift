import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex runtime approval must only compile in FUMINIWAExperimental")
#endif

enum CodexRuntimeApprovalCanonical {
    private static let magic = Data("FUMINIWA-CODEX-RUNTIME-APPROVAL\0".utf8)

    static func encode(_ components: CodexRuntimeApprovalPolicyComponents) throws -> Data {
        var writer = try CodexRuntimeCanonicalWriter(initialBytes: magic)
        try writer.append(components.policyVersion)
        try writer.append(components.policyGeneration)
        try writer.append(package: components.sdk)
        try writer.append(package: components.cli.package)
        try writer.append(package: components.cli.platformPackage)
        try writer.append(executable: components.cli.executable)
        try writer.append(string: components.node.version)
        try writer.append(components.node.architecture.rawValue)
        try writer.append(executable: components.node.executable)
        try writer.append(components.deploymentManifestVersion)
        try writer.append(lowercaseHex: components.deploymentRootSHA256, byteCount: 32)
        try writer.appendCount(components.inventory.count)
        for artifact in components.inventory {
            try writer.append(artifact: artifact)
        }
        try writer.appendCount(components.importEdges.count)
        for edge in components.importEdges {
            try writer.append(edge: edge)
        }
        return writer.data
    }

    static func checkedCanonicalByteCount(chunks: [Int]) throws -> Int {
        var total = 0
        for chunk in chunks {
            guard chunk >= 0 else {
                throw CodexRuntimeApprovalError.resourceLimit
            }
            total = try CodexRuntimeApprovalCheckedArithmetic.add(total, chunk)
            guard total <= CodexRuntimeApprovalLimits.maximumCanonicalBytes else {
                throw CodexRuntimeApprovalError.resourceLimit
            }
        }
        return total
    }
}

private struct CodexRuntimeCanonicalWriter {
    private(set) var data: Data

    init(initialBytes: Data) throws {
        guard initialBytes.count <= CodexRuntimeApprovalLimits.maximumCanonicalBytes else {
            throw CodexRuntimeApprovalError.resourceLimit
        }
        data = initialBytes
    }

    mutating func append(_ value: UInt8) throws {
        try append(Data([value]))
    }

    mutating func append(_ value: UInt32) throws {
        try appendFixedWidth(value.bigEndian)
    }

    mutating func append(_ value: UInt64) throws {
        try appendFixedWidth(value.bigEndian)
    }

    mutating func appendCount(_ count: Int) throws {
        guard let exact = UInt32(exactly: count) else {
            throw CodexRuntimeApprovalError.arithmeticOverflow
        }
        try append(exact)
    }

    mutating func append(string: String) throws {
        let bytes = Data(string.utf8)
        try appendCount(bytes.count)
        try append(bytes)
    }

    mutating func append(package: CodexRuntimePackagePin) throws {
        try append(string: package.version)
        guard let integrity = CodexRuntimeApprovalValidation.decodeSHA512SRI(
            package.integritySHA512
        ) else {
            throw CodexRuntimeApprovalError.invalidIntegrity
        }
        try append(integrity)
    }

    mutating func append(executable: CodexRuntimeExecutableIdentity) throws {
        try append(string: executable.relativePath)
        try append(executable.byteCount)
        try append(lowercaseHex: executable.sha256, byteCount: 32)
        try append(lowercaseHex: executable.cdHash, byteCount: 20)
    }

    mutating func append(artifact: CodexRuntimeInventoryArtifact) throws {
        try append(artifact.role.rawValue)
        try append(string: artifact.moduleID)
        try append(string: artifact.relativePath)
        switch artifact.content {
        case let .exactFile(byteCount, sha256):
            try append(UInt8(0x01))
            try append(byteCount)
            try append(lowercaseHex: sha256, byteCount: 32)
        case let .boundedRequestData(maximumByteCount):
            try append(UInt8(0x02))
            try append(maximumByteCount)
        case .operatingSystemProvided:
            try append(UInt8(0x03))
        case .forbidden:
            try append(UInt8(0x04))
        }
    }

    mutating func append(edge: CodexRuntimeImportEdge) throws {
        try append(edge.kind.rawValue)
        try append(string: edge.importerModuleID)
        try append(string: edge.importedModuleID)
    }

    mutating func append(lowercaseHex: String, byteCount: Int) throws {
        guard let decoded = CodexRuntimeApprovalValidation.decodeLowercaseHex(
            lowercaseHex,
            byteCount: byteCount
        ) else {
            throw CodexRuntimeApprovalError.invalidDigest
        }
        try append(decoded)
    }

    private mutating func append(_ bytes: Data) throws {
        let nextCount = try CodexRuntimeApprovalCheckedArithmetic.add(data.count, bytes.count)
        guard nextCount <= CodexRuntimeApprovalLimits.maximumCanonicalBytes else {
            throw CodexRuntimeApprovalError.resourceLimit
        }
        data.append(bytes)
    }

    private mutating func appendFixedWidth(_ value: some Any) throws {
        var mutableValue = value
        let bytes = withUnsafeBytes(of: &mutableValue) { Data($0) }
        try append(bytes)
    }
}

extension Data {
    var codexRuntimeLowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
