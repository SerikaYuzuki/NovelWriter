import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("SHA-256とCDHashはexact lowercase hexだけを受理する")
func codexRuntimeApprovalRequiresCanonicalLowercaseHashes() {
    let invalidSHA256 = [
        String(repeating: "A", count: 64),
        String(repeating: "a", count: 63),
        String(repeating: "a", count: 65),
        String(repeating: "g", count: 64)
    ]
    for sha256 in invalidSHA256 {
        #expect(
            capturedRuntimeApprovalError {
                _ = try makeRuntimeApprovalNode(sha256: sha256)
            } == .invalidDigest
        )
    }

    let invalidCDHashes = [
        String(repeating: "A", count: 40),
        String(repeating: "a", count: 39),
        String(repeating: "a", count: 41),
        String(repeating: "z", count: 40)
    ]
    for cdHash in invalidCDHashes {
        #expect(
            capturedRuntimeApprovalError {
                _ = try makeRuntimeApprovalNode(cdHash: cdHash)
            } == .invalidCDHash
        )
    }

    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(
                deploymentRootSHA256: String(repeating: "A", count: 64)
            )
        } == .invalidDigest
    )
}

@Test("package integrityはcanonical SHA-512 SRIだけを受理する")
func codexRuntimeApprovalRequiresCanonicalSHA512SRI() throws {
    let invalidIntegrities = [
        runtimeApprovalSDKIntegrity.replacingOccurrences(of: "sha512-", with: "sha256-"),
        String(runtimeApprovalSDKIntegrity.dropLast()),
        runtimeApprovalSDKIntegrity + "=",
        runtimeApprovalSDKIntegrity + "\n",
        "sha512-" + Data(repeating: 0x11, count: 63).base64EncodedString(),
        "sha512-not-base64"
    ]
    for integrity in invalidIntegrities {
        #expect(
            capturedRuntimeApprovalError {
                _ = try makeRuntimeApprovalSDKPin(integrity: integrity)
            } == .invalidIntegrity
        )
    }
    #expect(try makeRuntimeApprovalSDKPin().integritySHA512 == runtimeApprovalSDKIntegrity)
}

@Test("packageとNode versionはcanonical exact形式だけを受理する")
func codexRuntimeApprovalRequiresCanonicalVersions() throws {
    let invalidPackageVersions = [
        "",
        "v0.147.0",
        "0.0147.0",
        "0.147",
        "0.147.0-",
        "0.147.0-01",
        "0.147.0+build",
        "0.147.0/arm64",
        String(repeating: "1", count: CodexRuntimeApprovalLimits.maximumVersionBytes + 1)
    ]
    for version in invalidPackageVersions {
        #expect(
            capturedRuntimeApprovalError {
                _ = try makeRuntimeApprovalSDKPin(version: version)
            } == .invalidVersion
        )
    }

    let invalidNodeVersions = [
        "22.23.1",
        "V22.23.1",
        "v022.23.1",
        "v22.23",
        "v22.23.1+build"
    ]
    for version in invalidNodeVersions {
        #expect(
            capturedRuntimeApprovalError {
                _ = try makeRuntimeApprovalNode(version: version)
            } == .invalidVersion
        )
    }

    #expect(try makeRuntimeApprovalNode().version == "v22.23.1")
    #expect(try makeRuntimeApprovalPlatformPin().version == "0.147.0-darwin-arm64")
}

@Test("SDK・CLI・platform package versionはarchitectureごとに一体でpinする")
func codexRuntimeApprovalPinsSDKCLIAndArchitectureTogether() throws {
    let mismatchedCLI = try makeRuntimeApprovalCLI(
        package: makeRuntimeApprovalCLIPin(version: "0.148.0"),
        platformPackage: makeRuntimeApprovalPlatformPin(version: "0.148.0-darwin-arm64")
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(cli: mismatchedCLI)
        } == .inconsistentPackagePins
    )

    let wrongArchitecturePackage = try makeRuntimeApprovalCLI(
        platformPackage: makeRuntimeApprovalPlatformPin(version: "0.147.0-darwin-x64")
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(cli: wrongArchitecturePackage)
        } == .inconsistentPackagePins
    )

    let x86Node = try makeRuntimeApprovalNode(architecture: .x64)
    let x86CLI = try makeRuntimeApprovalCLI(
        platformPackage: makeRuntimeApprovalPlatformPin(version: "0.147.0-darwin-x64")
    )
    let x86Policy = try makeRuntimeApprovalPolicy(cli: x86CLI, node: x86Node)
    let armPolicy = try makeRuntimeApprovalPolicy()
    #expect(x86Policy.node.architecture == .x64)
    #expect(armPolicy.node.architecture == .arm64)
    #expect(x86Policy.sha256 != armPolicy.sha256)
}

@Test("relative pathはabsolute・traversal・非NFC・control・backslashを拒否する")
func codexRuntimeApprovalRejectsUnsafeRelativePaths() throws {
    let invalidPaths = [
        "",
        "/runtime/node",
        "runtime/node/",
        "runtime//node",
        "runtime/./node",
        "runtime/../node",
        "runtime\\node",
        "runtime/\u{0000}node",
        "runtime/\u{007F}node",
        "runtime/\u{0085}node",
        "runtime/\u{200B}node",
        "runtime/\u{2028}node",
        "runtime/\u{2029}node",
        "runtime/\u{202E}node",
        "runtime/e\u{0301}.mjs",
        String(repeating: "a", count: CodexRuntimeApprovalLimits.maximumPathComponentBytes + 1),
        String(repeating: "a/", count: 2048) + "a"
    ]
    for path in invalidPaths {
        do {
            _ = try makeRuntimeApprovalNode(relativePath: path)
            Issue.record("accepted unsafe path: \(path.debugDescription)")
        } catch let error as CodexRuntimeApprovalError {
            #expect(error == .invalidPath)
        }
    }

    let composedPath = try makeRuntimeApprovalNode(
        relativePath: "runtime/é/node"
    ).executable.relativePath
    #expect(composedPath == "runtime/é/node")
}

@Test("relative pathとcomponent byte capはexact値を許可し1 byte超過を拒否する")
func codexRuntimeApprovalPathLimitsHaveExactBoundaries() throws {
    let exactComponent = String(
        repeating: "a",
        count: CodexRuntimeApprovalLimits.maximumPathComponentBytes
    )
    #expect(
        try makeRuntimeApprovalNode(relativePath: exactComponent).executable.relativePath ==
            exactComponent
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalNode(relativePath: exactComponent + "a")
        } == .invalidPath
    )

    let exactPath = Array(repeating: exactComponent, count: 15)
        .appending(String(repeating: "b", count: 254))
        .appending("c")
        .joined(separator: "/")
    #expect(exactPath.utf8.count == CodexRuntimeApprovalLimits.maximumRelativePathBytes)
    #expect(try makeRuntimeApprovalNode(relativePath: exactPath).executable.relativePath == exactPath)
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalNode(relativePath: exactPath + "d")
        } == .invalidPath
    )
}

@Test("module IDはbounded ASCII componentだけを受理する")
func codexRuntimeApprovalRejectsUnsafeModuleIDs() {
    let invalidIDs = [
        "",
        "/sdk.bundle",
        "sdk.bundle/",
        "sdk//bundle",
        "sdk/./bundle",
        "sdk/../bundle",
        "sdk\\bundle",
        "日本語",
        String(repeating: "a", count: CodexRuntimeApprovalLimits.maximumModuleIDBytes + 1)
    ]
    for moduleID in invalidIDs {
        #expect(
            capturedRuntimeApprovalError {
                _ = try makeRuntimeApprovalArtifact(
                    moduleID: moduleID,
                    relativePath: "safe/path",
                    role: .forbidden,
                    content: .forbidden
                )
            } == .invalidModuleID
        )
    }
}

@Test("module ID byte capはexact値を許可し1 byte超過を拒否する")
func codexRuntimeApprovalModuleIDLimitHasExactBoundary() throws {
    let exact = String(repeating: "a", count: CodexRuntimeApprovalLimits.maximumModuleIDBytes)
    #expect(
        try makeRuntimeApprovalArtifact(
            moduleID: exact,
            relativePath: "safe/path",
            role: .forbidden,
            content: .forbidden
        ).moduleID == exact
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalArtifact(
                moduleID: exact + "a",
                relativePath: "safe/path",
                role: .forbidden,
                content: .forbidden
            )
        } == .invalidModuleID
    )
}

@Test("policyとmanifest version・generationをexactに固定する")
func codexRuntimeApprovalRequiresCurrentPolicyEnvelope() {
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(policyVersion: 2)
        } == .unsupportedPolicyVersion
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(policyGeneration: 0)
        } == .invalidPolicyGeneration
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(deploymentManifestVersion: 2)
        } == .unsupportedPolicyVersion
    )
}

private extension [String] {
    func appending(_ value: String) -> [String] {
        self + [value]
    }
}
