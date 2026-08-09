import CryptoKit
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex runtime approval must only compile in FUMINIWAExperimental")
#endif

struct CodexRuntimeApprovalValidatedPolicy {
    let inventory: [CodexRuntimeInventoryArtifact]
    let importEdges: [CodexRuntimeImportEdge]
    let canonicalBytes: Data
    let sha256: String
}

private struct CodexRuntimeInventoryBudget {
    private var exactBytes: UInt64 = 0
    private var requestBytes: UInt64 = 0

    mutating func include(_ content: CodexRuntimeArtifactContentIdentity) throws {
        switch content {
        case let .exactFile(byteCount, _):
            exactBytes = try CodexRuntimeApprovalCheckedArithmetic.add(exactBytes, byteCount)
            guard exactBytes <= CodexRuntimeApprovalLimits.maximumTotalExactArtifactBytes else {
                throw CodexRuntimeApprovalError.resourceLimit
            }
        case let .boundedRequestData(maximumByteCount):
            requestBytes = try CodexRuntimeApprovalCheckedArithmetic.add(
                requestBytes,
                maximumByteCount
            )
            guard requestBytes <= CodexRuntimeApprovalLimits.maximumTotalRequestDataBytes else {
                throw CodexRuntimeApprovalError.resourceLimit
            }
        case .operatingSystemProvided, .forbidden:
            break
        }
    }
}

enum CodexRuntimeApprovalValidator {
    static func validate(
        _ components: CodexRuntimeApprovalPolicyComponents
    ) throws -> CodexRuntimeApprovalValidatedPolicy {
        guard components.policyVersion == CodexRuntimeApprovalLimits.currentPolicyVersion else {
            throw CodexRuntimeApprovalError.unsupportedPolicyVersion
        }
        guard components.policyGeneration > 0 else {
            throw CodexRuntimeApprovalError.invalidPolicyGeneration
        }
        guard components.deploymentManifestVersion == 1 else {
            throw CodexRuntimeApprovalError.unsupportedPolicyVersion
        }
        guard CodexRuntimeApprovalValidation.decodeLowercaseHex(
            components.deploymentRootSHA256,
            byteCount: 32
        ) != nil else {
            throw CodexRuntimeApprovalError.invalidDigest
        }
        try validatePackagePins(
            sdk: components.sdk,
            cli: components.cli,
            architecture: components.node.architecture
        )
        let sortedInventory = try validateInventory(
            components.inventory,
            node: components.node,
            cli: components.cli
        )
        let sortedEdges = try validateImportEdges(
            components.importEdges,
            inventory: sortedInventory
        )
        let canonicalComponents = CodexRuntimeApprovalPolicyComponents(
            policyVersion: components.policyVersion,
            policyGeneration: components.policyGeneration,
            sdk: components.sdk,
            cli: components.cli,
            node: components.node,
            deploymentManifestVersion: components.deploymentManifestVersion,
            deploymentRootSHA256: components.deploymentRootSHA256,
            inventory: sortedInventory,
            importEdges: sortedEdges
        )
        let canonicalBytes = try CodexRuntimeApprovalCanonical.encode(canonicalComponents)
        return CodexRuntimeApprovalValidatedPolicy(
            inventory: sortedInventory,
            importEdges: sortedEdges,
            canonicalBytes: canonicalBytes,
            sha256: Data(SHA256.hash(data: canonicalBytes)).codexRuntimeLowercaseHex
        )
    }

    private static func validatePackagePins(
        sdk: CodexRuntimePackagePin,
        cli: CodexRuntimeCLIIdentity,
        architecture: CodexRuntimeArchitecture
    ) throws {
        guard sdk.version == cli.package.version else {
            throw CodexRuntimeApprovalError.inconsistentPackagePins
        }
        let expectedPlatformVersion = "\(cli.package.version)-darwin-\(architecture.platformPackageSuffix)"
        guard cli.platformPackage.version == expectedPlatformVersion else {
            throw CodexRuntimeApprovalError.inconsistentPackagePins
        }
    }

    private static func validateInventory(
        _ inventory: [CodexRuntimeInventoryArtifact],
        node: CodexRuntimeNodeIdentity,
        cli: CodexRuntimeCLIIdentity
    ) throws -> [CodexRuntimeInventoryArtifact] {
        let isBoundedInventory = !inventory.isEmpty
            && inventory.count <= CodexRuntimeApprovalLimits.maximumInventoryCount
        guard isBoundedInventory else {
            throw CodexRuntimeApprovalError.resourceLimit
        }

        var moduleIDs = Set<String>()
        var paths = Set<String>()
        var roles = Set<CodexRuntimeInventoryRole>()
        var budget = CodexRuntimeInventoryBudget()
        for artifact in inventory {
            guard moduleIDs.insert(artifact.moduleID).inserted else {
                throw CodexRuntimeApprovalError.duplicateModuleID
            }
            guard paths.insert(artifact.relativePath).inserted else {
                throw CodexRuntimeApprovalError.duplicatePath
            }
            roles.insert(artifact.role)
            try budget.include(artifact.content)
        }
        guard roles == Set(CodexRuntimeInventoryRole.allCases) else {
            throw CodexRuntimeApprovalError.missingInventoryRole
        }
        let hasDistinctExecutablePaths = node.executable.relativePath != cli.executable.relativePath
        let hasNode = inventory.contains(where: { matches($0, executable: node.executable) })
        let hasCLI = inventory.contains(where: { matches($0, executable: cli.executable) })
        guard hasDistinctExecutablePaths, hasNode, hasCLI else {
            throw CodexRuntimeApprovalError.executableIdentityMismatch
        }
        return inventory.sorted(by: artifactPrecedes)
    }

    private static func validateImportEdges(
        _ importEdges: [CodexRuntimeImportEdge],
        inventory: [CodexRuntimeInventoryArtifact]
    ) throws -> [CodexRuntimeImportEdge] {
        guard importEdges.count <= CodexRuntimeApprovalLimits.maximumImportEdgeCount else {
            throw CodexRuntimeApprovalError.resourceLimit
        }
        let artifacts = Dictionary(uniqueKeysWithValues: inventory.map { ($0.moduleID, $0) })
        var uniqueEdges = Set<CodexRuntimeImportEdge>()
        for edge in importEdges {
            guard uniqueEdges.insert(edge).inserted else {
                throw CodexRuntimeApprovalError.duplicateImportEdge
            }
            let importer = artifacts[edge.importerModuleID]
            let imported = artifacts[edge.importedModuleID]
            guard let importer, let imported else {
                throw CodexRuntimeApprovalError.unknownImportEndpoint
            }
            let isValidImporter = [
                CodexRuntimeInventoryRole.evaluatedSource,
                .conditional,
                .executable
            ].contains(importer.role)
            let isValidEdge = edge.importerModuleID != edge.importedModuleID
                && isValidImporter
                && imported.role != .forbidden
            guard isValidEdge else {
                throw CodexRuntimeApprovalError.invalidImportEdge
            }
            try validateImportKind(edge.kind, importedRole: imported.role)
        }
        return importEdges.sorted(by: importEdgePrecedes)
    }

    private static func validateImportKind(
        _ kind: CodexRuntimeImportKind,
        importedRole: CodexRuntimeInventoryRole
    ) throws {
        let accepted: Set<CodexRuntimeInventoryRole> = switch kind {
        case .staticESM, .dynamicESM, .commonJS:
            [.evaluatedSource, .conditional, .operatingSystemTrust]
        case .nativeAddon, .executableSpawn:
            [.executable, .conditional, .operatingSystemTrust]
        case .runtimeDataRead:
            [
                .resolutionMetadata,
                .conditional,
                .requestData,
                .operatingSystemTrust
            ]
        }
        guard accepted.contains(importedRole) else {
            throw CodexRuntimeApprovalError.invalidImportEdge
        }
    }

    private static func matches(
        _ artifact: CodexRuntimeInventoryArtifact,
        executable: CodexRuntimeExecutableIdentity
    ) -> Bool {
        let hasMatchingSlot = artifact.role == .executable
            && artifact.relativePath == executable.relativePath
        guard hasMatchingSlot else {
            return false
        }
        guard case let .exactFile(byteCount, sha256) = artifact.content else {
            return false
        }
        return byteCount == executable.byteCount && sha256 == executable.sha256
    }

    private static func artifactPrecedes(
        _ left: CodexRuntimeInventoryArtifact,
        _ right: CodexRuntimeInventoryArtifact
    ) -> Bool {
        Data(left.moduleID.utf8).lexicographicallyPrecedes(Data(right.moduleID.utf8))
    }

    private static func importEdgePrecedes(
        _ left: CodexRuntimeImportEdge,
        _ right: CodexRuntimeImportEdge
    ) -> Bool {
        let leftKey = (left.importerModuleID, left.importedModuleID, left.kind.rawValue)
        let rightKey = (right.importerModuleID, right.importedModuleID, right.kind.rawValue)
        if leftKey.0 != rightKey.0 {
            return Data(leftKey.0.utf8).lexicographicallyPrecedes(Data(rightKey.0.utf8))
        }
        if leftKey.1 != rightKey.1 {
            return Data(leftKey.1.utf8).lexicographicallyPrecedes(Data(rightKey.1.utf8))
        }
        return leftKey.2 < rightKey.2
    }
}
