import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex runtime approval must only compile in FUMINIWAExperimental")
#endif

enum CodexRuntimeApprovalError: String, Error, Sendable, Equatable {
    case unsupportedPolicyVersion = "unsupported_policy_version"
    case invalidPolicyGeneration = "invalid_policy_generation"
    case invalidVersion = "invalid_version"
    case invalidIntegrity = "invalid_integrity"
    case inconsistentPackagePins = "inconsistent_package_pins"
    case invalidPath = "invalid_path"
    case invalidModuleID = "invalid_module_id"
    case invalidDigest = "invalid_digest"
    case invalidCDHash = "invalid_cdhash"
    case invalidByteCount = "invalid_byte_count"
    case invalidArtifactContent = "invalid_artifact_content"
    case duplicateModuleID = "duplicate_module_id"
    case duplicatePath = "duplicate_path"
    case duplicateImportEdge = "duplicate_import_edge"
    case missingInventoryRole = "missing_inventory_role"
    case unknownImportEndpoint = "unknown_import_endpoint"
    case invalidImportEdge = "invalid_import_edge"
    case executableIdentityMismatch = "executable_identity_mismatch"
    case arithmeticOverflow = "arithmetic_overflow"
    case resourceLimit = "resource_limit"
    case approvalUnavailable = "approval_unavailable"
}

enum CodexRuntimeArchitecture: UInt8, CaseIterable, Sendable, Equatable {
    case arm64 = 0x01
    case x64 = 0x02

    var platformPackageSuffix: String {
        switch self {
        case .arm64:
            "arm64"
        case .x64:
            "x64"
        }
    }
}

struct CodexRuntimePackagePin: Sendable, Equatable {
    let version: String
    let integritySHA512: String

    init(version: String, integritySHA512: String) throws {
        guard CodexRuntimeApprovalValidation.isExactVersion(version) else {
            throw CodexRuntimeApprovalError.invalidVersion
        }
        guard CodexRuntimeApprovalValidation.decodeSHA512SRI(integritySHA512) != nil else {
            throw CodexRuntimeApprovalError.invalidIntegrity
        }
        self.version = version
        self.integritySHA512 = integritySHA512
    }
}

struct CodexRuntimeExecutableIdentity: Sendable, Equatable {
    let relativePath: String
    let byteCount: UInt64
    let sha256: String
    let cdHash: String

    init(
        relativePath: String,
        byteCount: UInt64,
        sha256: String,
        cdHash: String
    ) throws {
        try CodexRuntimeApprovalValidation.requireCanonicalRelativePath(relativePath)
        let isValidByteCount = byteCount > 0
            && byteCount <= CodexRuntimeApprovalLimits.maximumExactArtifactBytes
        guard isValidByteCount else {
            throw CodexRuntimeApprovalError.invalidByteCount
        }
        guard CodexRuntimeApprovalValidation.decodeLowercaseHex(sha256, byteCount: 32) != nil else {
            throw CodexRuntimeApprovalError.invalidDigest
        }
        guard CodexRuntimeApprovalValidation.decodeLowercaseHex(cdHash, byteCount: 20) != nil else {
            throw CodexRuntimeApprovalError.invalidCDHash
        }
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.cdHash = cdHash
    }
}

struct CodexRuntimeNodeIdentity: Sendable, Equatable {
    let version: String
    let architecture: CodexRuntimeArchitecture
    let executable: CodexRuntimeExecutableIdentity

    init(
        version: String,
        architecture: CodexRuntimeArchitecture,
        relativePath: String,
        byteCount: UInt64,
        sha256: String,
        cdHash: String
    ) throws {
        guard CodexRuntimeApprovalValidation.isNodeVersion(version) else {
            throw CodexRuntimeApprovalError.invalidVersion
        }
        self.version = version
        self.architecture = architecture
        executable = try CodexRuntimeExecutableIdentity(
            relativePath: relativePath,
            byteCount: byteCount,
            sha256: sha256,
            cdHash: cdHash
        )
    }
}

struct CodexRuntimeCLIIdentity: Sendable, Equatable {
    let package: CodexRuntimePackagePin
    let platformPackage: CodexRuntimePackagePin
    let executable: CodexRuntimeExecutableIdentity

    init(
        package: CodexRuntimePackagePin,
        platformPackage: CodexRuntimePackagePin,
        relativePath: String,
        byteCount: UInt64,
        sha256: String,
        cdHash: String
    ) throws {
        self.package = package
        self.platformPackage = platformPackage
        executable = try CodexRuntimeExecutableIdentity(
            relativePath: relativePath,
            byteCount: byteCount,
            sha256: sha256,
            cdHash: cdHash
        )
    }
}

enum CodexRuntimeInventoryRole: UInt8, CaseIterable, Sendable, Equatable {
    case evaluatedSource = 0x01
    case resolutionMetadata = 0x02
    case executable = 0x03
    case conditional = 0x04
    case provenance = 0x05
    case requestData = 0x06
    case operatingSystemTrust = 0x07
    case forbidden = 0x08
}

enum CodexRuntimeArtifactContentIdentity: Sendable, Equatable {
    case exactFile(byteCount: UInt64, sha256: String)
    case boundedRequestData(maximumByteCount: UInt64)
    case operatingSystemProvided
    case forbidden
}

struct CodexRuntimeInventoryArtifact: Sendable, Equatable {
    let moduleID: String
    let relativePath: String
    let role: CodexRuntimeInventoryRole
    let content: CodexRuntimeArtifactContentIdentity

    init(
        moduleID: String,
        relativePath: String,
        role: CodexRuntimeInventoryRole,
        content: CodexRuntimeArtifactContentIdentity
    ) throws {
        try CodexRuntimeApprovalValidation.requireCanonicalModuleID(moduleID)
        try CodexRuntimeApprovalValidation.requireCanonicalRelativePath(relativePath)
        try CodexRuntimeApprovalValidation.requireContent(content, for: role)
        self.moduleID = moduleID
        self.relativePath = relativePath
        self.role = role
        self.content = content
    }
}

enum CodexRuntimeImportKind: UInt8, CaseIterable, Sendable, Equatable {
    case staticESM = 0x01
    case dynamicESM = 0x02
    case commonJS = 0x03
    case nativeAddon = 0x04
    case executableSpawn = 0x05
    case runtimeDataRead = 0x06
}

struct CodexRuntimeImportEdge: Sendable, Equatable, Hashable {
    let importerModuleID: String
    let importedModuleID: String
    let kind: CodexRuntimeImportKind

    init(
        importerModuleID: String,
        importedModuleID: String,
        kind: CodexRuntimeImportKind
    ) throws {
        try CodexRuntimeApprovalValidation.requireCanonicalModuleID(importerModuleID)
        try CodexRuntimeApprovalValidation.requireCanonicalModuleID(importedModuleID)
        self.importerModuleID = importerModuleID
        self.importedModuleID = importedModuleID
        self.kind = kind
    }
}

struct CodexRuntimeApprovalPolicy: Sendable, Equatable {
    let policyVersion: UInt32
    let policyGeneration: UInt64
    let sdk: CodexRuntimePackagePin
    let cli: CodexRuntimeCLIIdentity
    let node: CodexRuntimeNodeIdentity
    let deploymentManifestVersion: UInt32
    let deploymentRootSHA256: String
    let inventory: [CodexRuntimeInventoryArtifact]
    let importEdges: [CodexRuntimeImportEdge]
    let canonicalBytes: Data
    let sha256: String

    init(
        validating policyVersion: UInt32,
        policyGeneration: UInt64,
        sdk: CodexRuntimePackagePin,
        cli: CodexRuntimeCLIIdentity,
        node: CodexRuntimeNodeIdentity,
        deploymentManifestVersion: UInt32,
        deploymentRootSHA256: String,
        inventory: [CodexRuntimeInventoryArtifact],
        importEdges: [CodexRuntimeImportEdge]
    ) throws {
        let components = CodexRuntimeApprovalPolicyComponents(
            policyVersion: policyVersion,
            policyGeneration: policyGeneration,
            sdk: sdk,
            cli: cli,
            node: node,
            deploymentManifestVersion: deploymentManifestVersion,
            deploymentRootSHA256: deploymentRootSHA256,
            inventory: inventory,
            importEdges: importEdges
        )
        let validated = try CodexRuntimeApprovalValidator.validate(components)
        self.policyVersion = policyVersion
        self.policyGeneration = policyGeneration
        self.sdk = sdk
        self.cli = cli
        self.node = node
        self.deploymentManifestVersion = deploymentManifestVersion
        self.deploymentRootSHA256 = deploymentRootSHA256
        self.inventory = validated.inventory
        self.importEdges = validated.importEdges
        canonicalBytes = validated.canonicalBytes
        sha256 = validated.sha256
    }
}

struct CodexRuntimeApprovalProposal: Sendable, Equatable {
    let policy: CodexRuntimeApprovalPolicy
    let policySHA256: String

    init(policy: CodexRuntimeApprovalPolicy) {
        self.policy = policy
        policySHA256 = policy.sha256
    }
}

enum CodexRuntimeApprovalLimits {
    static let currentPolicyVersion: UInt32 = 1
    static let maximumVersionBytes = 128
    static let maximumModuleIDBytes = 256
    static let maximumRelativePathBytes = 4096
    static let maximumPathComponentBytes = 255
    static let maximumInventoryCount = 4096
    static let maximumImportEdgeCount = 16384
    static let maximumExactArtifactBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maximumTotalExactArtifactBytes: UInt64 = 8 * 1024 * 1024 * 1024
    static let maximumRequestDataBytes: UInt64 = 16 * 1024 * 1024
    static let maximumTotalRequestDataBytes: UInt64 = 64 * 1024 * 1024
    static let maximumCanonicalBytes = 4 * 1024 * 1024
}

struct CodexRuntimeApprovalPolicyComponents {
    let policyVersion: UInt32
    let policyGeneration: UInt64
    let sdk: CodexRuntimePackagePin
    let cli: CodexRuntimeCLIIdentity
    let node: CodexRuntimeNodeIdentity
    let deploymentManifestVersion: UInt32
    let deploymentRootSHA256: String
    let inventory: [CodexRuntimeInventoryArtifact]
    let importEdges: [CodexRuntimeImportEdge]
}
