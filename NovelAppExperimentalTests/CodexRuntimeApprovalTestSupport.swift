import Foundation
@testable import FUMINIWAExperimental
import Testing

let runtimeApprovalSDKIntegrity =
    "sha512-EREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREQ=="
let runtimeApprovalCLIIntegrity =
    "sha512-IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIg=="
let runtimeApprovalPlatformIntegrity =
    "sha512-MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMw=="

let runtimeApprovalNodePath = "runtime/node/bin/node"
let runtimeApprovalCLIPath =
    "node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex"
let runtimeApprovalNodeByteCount: UInt64 = 42_000_000
let runtimeApprovalCLIByteCount: UInt64 = 14_000_000
let runtimeApprovalNodeSHA256 = String(repeating: "4", count: 64)
let runtimeApprovalNodeCDHash = String(repeating: "5", count: 40)
let runtimeApprovalCLISHA256 = String(repeating: "6", count: 64)
let runtimeApprovalCLICDHash = String(repeating: "7", count: 40)
let runtimeApprovalDeploymentSHA256 = String(repeating: "8", count: 64)

func makeRuntimeApprovalSDKPin(
    version: String = "0.147.0",
    integrity: String = runtimeApprovalSDKIntegrity
) throws -> CodexRuntimePackagePin {
    try CodexRuntimePackagePin(version: version, integritySHA512: integrity)
}

func makeRuntimeApprovalCLIPin(
    version: String = "0.147.0",
    integrity: String = runtimeApprovalCLIIntegrity
) throws -> CodexRuntimePackagePin {
    try CodexRuntimePackagePin(version: version, integritySHA512: integrity)
}

func makeRuntimeApprovalPlatformPin(
    version: String = "0.147.0-darwin-arm64",
    integrity: String = runtimeApprovalPlatformIntegrity
) throws -> CodexRuntimePackagePin {
    try CodexRuntimePackagePin(version: version, integritySHA512: integrity)
}

func makeRuntimeApprovalNode(
    version: String = "v22.23.1",
    architecture: CodexRuntimeArchitecture = .arm64,
    relativePath: String = runtimeApprovalNodePath,
    byteCount: UInt64 = runtimeApprovalNodeByteCount,
    sha256: String = runtimeApprovalNodeSHA256,
    cdHash: String = runtimeApprovalNodeCDHash
) throws -> CodexRuntimeNodeIdentity {
    try CodexRuntimeNodeIdentity(
        version: version,
        architecture: architecture,
        relativePath: relativePath,
        byteCount: byteCount,
        sha256: sha256,
        cdHash: cdHash
    )
}

func makeRuntimeApprovalCLI(
    package: CodexRuntimePackagePin? = nil,
    platformPackage: CodexRuntimePackagePin? = nil,
    relativePath: String = runtimeApprovalCLIPath,
    byteCount: UInt64 = runtimeApprovalCLIByteCount,
    sha256: String = runtimeApprovalCLISHA256,
    cdHash: String = runtimeApprovalCLICDHash
) throws -> CodexRuntimeCLIIdentity {
    try CodexRuntimeCLIIdentity(
        package: package ?? makeRuntimeApprovalCLIPin(),
        platformPackage: platformPackage ?? makeRuntimeApprovalPlatformPin(),
        relativePath: relativePath,
        byteCount: byteCount,
        sha256: sha256,
        cdHash: cdHash
    )
}

func makeRuntimeApprovalArtifact(
    moduleID: String,
    relativePath: String,
    role: CodexRuntimeInventoryRole,
    content: CodexRuntimeArtifactContentIdentity
) throws -> CodexRuntimeInventoryArtifact {
    try CodexRuntimeInventoryArtifact(
        moduleID: moduleID,
        relativePath: relativePath,
        role: role,
        content: content
    )
}

func runtimeApprovalInventory() throws -> [CodexRuntimeInventoryArtifact] {
    let runtime = try runtimeApprovalRuntimeInventory()
    let boundary = try runtimeApprovalBoundaryInventory()
    return runtime + boundary
}

private func runtimeApprovalRuntimeInventory() throws -> [CodexRuntimeInventoryArtifact] {
    try [
        makeRuntimeApprovalArtifact(
            moduleID: "sidecar.entry",
            relativePath: "sidecar/main.mjs",
            role: .evaluatedSource,
            content: .exactFile(
                byteCount: 101,
                sha256: String(repeating: "9", count: 64)
            )
        ),
        makeRuntimeApprovalArtifact(
            moduleID: "sdk.bundle",
            relativePath: "node_modules/@openai/codex-sdk/dist/index.js",
            role: .evaluatedSource,
            content: .exactFile(
                byteCount: 202,
                sha256: String(repeating: "a", count: 64)
            )
        ),
        makeRuntimeApprovalArtifact(
            moduleID: "sdk.package",
            relativePath: "node_modules/@openai/codex-sdk/package.json",
            role: .resolutionMetadata,
            content: .exactFile(
                byteCount: 303,
                sha256: String(repeating: "b", count: 64)
            )
        ),
        makeRuntimeApprovalArtifact(
            moduleID: "node.runtime",
            relativePath: runtimeApprovalNodePath,
            role: .executable,
            content: .exactFile(
                byteCount: runtimeApprovalNodeByteCount,
                sha256: runtimeApprovalNodeSHA256
            )
        ),
        makeRuntimeApprovalArtifact(
            moduleID: "codex.cli",
            relativePath: runtimeApprovalCLIPath,
            role: .executable,
            content: .exactFile(
                byteCount: runtimeApprovalCLIByteCount,
                sha256: runtimeApprovalCLISHA256
            )
        )
    ]
}

private func runtimeApprovalBoundaryInventory() throws -> [CodexRuntimeInventoryArtifact] {
    try [
        makeRuntimeApprovalArtifact(
            moduleID: "sdk.lazy-source",
            relativePath: "node_modules/@openai/codex-sdk/dist/lazy.js",
            role: .conditional,
            content: .exactFile(
                byteCount: 404,
                sha256: String(repeating: "c", count: 64)
            )
        ),
        makeRuntimeApprovalArtifact(
            moduleID: "package.lock",
            relativePath: "package-lock.json",
            role: .provenance,
            content: .exactFile(
                byteCount: 505,
                sha256: String(repeating: "d", count: 64)
            )
        ),
        makeRuntimeApprovalArtifact(
            moduleID: "request.payload",
            relativePath: "request/payload",
            role: .requestData,
            content: .boundedRequestData(maximumByteCount: 524_288)
        ),
        makeRuntimeApprovalArtifact(
            moduleID: "apple.security",
            relativePath: "os/apple-sealed/Security.framework",
            role: .operatingSystemTrust,
            content: .operatingSystemProvided
        ),
        makeRuntimeApprovalArtifact(
            moduleID: "ambient.plugin",
            relativePath: "ambient/plugin",
            role: .forbidden,
            content: .forbidden
        )
    ]
}

func runtimeApprovalImportEdges() throws -> [CodexRuntimeImportEdge] {
    try [
        CodexRuntimeImportEdge(
            importerModuleID: "sidecar.entry",
            importedModuleID: "sdk.bundle",
            kind: .staticESM
        ),
        CodexRuntimeImportEdge(
            importerModuleID: "sdk.bundle",
            importedModuleID: "sdk.package",
            kind: .runtimeDataRead
        ),
        CodexRuntimeImportEdge(
            importerModuleID: "sdk.bundle",
            importedModuleID: "sdk.lazy-source",
            kind: .dynamicESM
        ),
        CodexRuntimeImportEdge(
            importerModuleID: "sdk.bundle",
            importedModuleID: "codex.cli",
            kind: .executableSpawn
        )
    ]
}

func makeRuntimeApprovalPolicy(
    policyVersion: UInt32 = CodexRuntimeApprovalLimits.currentPolicyVersion,
    policyGeneration: UInt64 = 7,
    sdk: CodexRuntimePackagePin? = nil,
    cli: CodexRuntimeCLIIdentity? = nil,
    node: CodexRuntimeNodeIdentity? = nil,
    deploymentManifestVersion: UInt32 = CodexDeploymentManifestLimits.version,
    deploymentRootSHA256: String = runtimeApprovalDeploymentSHA256,
    inventory: [CodexRuntimeInventoryArtifact]? = nil,
    importEdges: [CodexRuntimeImportEdge]? = nil
) throws -> CodexRuntimeApprovalPolicy {
    try CodexRuntimeApprovalPolicy(
        validating: policyVersion,
        policyGeneration: policyGeneration,
        sdk: sdk ?? makeRuntimeApprovalSDKPin(),
        cli: cli ?? makeRuntimeApprovalCLI(),
        node: node ?? makeRuntimeApprovalNode(),
        deploymentManifestVersion: deploymentManifestVersion,
        deploymentRootSHA256: deploymentRootSHA256,
        inventory: inventory ?? runtimeApprovalInventory(),
        importEdges: importEdges ?? runtimeApprovalImportEdges()
    )
}

func capturedRuntimeApprovalError(
    _ operation: () throws -> Void
) -> CodexRuntimeApprovalError? {
    do {
        try operation()
        Issue.record("expected CodexRuntimeApprovalError")
        return nil
    } catch let error as CodexRuntimeApprovalError {
        return error
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}
