import Foundation
@testable import FUMINIWAExperimental
import Testing

private let nodeOracleDigest =
    "15b98ccfac850c24e2427249c55c9fba5aba29b6ef1632301136688c13d35288"
private let nodeOracleCanonicalBase64 = [
    "RlVNSU5JV0EtQ09ERVgtREVQTE9ZTUVOVC1NQU5JRkVTVAAAAAABAAAAAAAAAAUAAAAAAAAABwEAAAAA",
    "AcAAAAAAAAAAOgIAAAALYS1maXJzdC50eHQBpAAAAAAAAAAFjtP2rWhblZ6tcCJRjhr3bNgW+OjsfM3a",
    "HtQBjo8iI/gAAAAAAAAACgEAAAADbGliAe0AAAAAAAAAOwIAAAAMbGliL21haW4ubWpzAaQAAAAAAAAA",
    "EpaQnh3OhcpTT9iIH2yDaaiofgbfWkv4HvRKctsZWwcEAAAAAAAAADkCAAAACnotbGFzdC50eHQBgAAA",
    "AAAAAAABWU5RmuSZMSspQzt92Kl/8Gje/LqXVbbV0A6ExSTWewY="
].joined()

@Test("Swift manifestはNode canonical v1 oracleとdigest・bytes・record順が一致する")
func codexDeploymentManifestMatchesNodeOracle() throws {
    let root = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
        at: root.appending(path: "lib", directoryHint: .isDirectory),
        withIntermediateDirectories: false
    )
    #expect(chmod(root.appending(path: "lib").path, 0o755) == 0)
    try writeManifestFile(root: root, relativePath: "z-last.txt", contents: "z", mode: 0o600)
    try writeManifestFile(
        root: root,
        relativePath: "lib/main.mjs",
        contents: "export default 1;\n"
    )
    try writeManifestFile(root: root, relativePath: "a-first.txt", contents: "alpha")

    let manifest = try CodexDeploymentManifestVerifier.create(rootPath: root.path)

    #expect(manifest.version == 1)
    #expect(manifest.rootDigest == nodeOracleDigest)
    #expect(manifest.canonicalBytes.count == 278)
    #expect(manifest.canonicalBytes.base64EncodedString() == nodeOracleCanonicalBase64)
    #expect(manifest.records.map(\.path) == [
        "",
        "a-first.txt",
        "lib",
        "lib/main.mjs",
        "z-last.txt"
    ])
    #expect(manifest.records.map(\.kind) == [
        .directory,
        .file,
        .directory,
        .file,
        .file
    ])
    #expect(manifest.records.map(\.mode) == [0o700, 0o644, 0o755, 0o644, 0o600])
    #expect(manifest.records[1].size == 5)
    #expect(
        manifest.records[1].sha256 ==
            "8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8"
    )

    let repeated = try CodexDeploymentManifestVerifier.create(rootPath: root.path)
    #expect(repeated == manifest)
    #expect(
        try CodexDeploymentManifestVerifier.verify(
            rootPath: root.path,
            expectedRootDigest: nodeOracleDigest
        ) == manifest
    )
}

@Test("UTF-8 path bytesだけでsortし作成順とroot位置に依存しない")
func codexDeploymentManifestUsesUnsignedUTF8Ordering() throws {
    let firstRoot = try makeManifestTemporaryRoot()
    let secondRoot = try makeManifestTemporaryRoot()
    defer {
        try? FileManager.default.removeItem(at: firstRoot)
        try? FileManager.default.removeItem(at: secondRoot)
    }

    for name in ["z.txt", "😀.txt", "a.txt"] {
        try writeManifestFile(root: firstRoot, relativePath: name, contents: "content:\(name)")
    }
    for name in ["a.txt", "😀.txt", "z.txt"] {
        try writeManifestFile(root: secondRoot, relativePath: name, contents: "content:\(name)")
    }

    let first = try CodexDeploymentManifestVerifier.create(rootPath: firstRoot.path)
    let second = try CodexDeploymentManifestVerifier.create(rootPath: secondRoot.path)
    #expect(second.records.map(\.path) == ["", "a.txt", "z.txt", "😀.txt"])
    #expect(first.canonicalBytes == second.canonicalBytes)
    #expect(first.rootDigest == second.rootDigest)
}

@Test("expected digestは独立引数のlowercase SHA-256だけを受理する")
func codexDeploymentManifestRequiresIndependentCanonicalDigest() throws {
    let root = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeManifestFile(root: root, relativePath: "main.mjs", contents: "export {};\n")
    let digest = try CodexDeploymentManifestVerifier.create(rootPath: root.path).rootDigest

    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestVerifier.verify(
                rootPath: root.path,
                expectedRootDigest: digest.uppercased()
            )
        } == .invalidDigest
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestVerifier.verify(
                rootPath: root.path,
                expectedRootDigest: String(repeating: "0", count: 64)
            )
        } == .digestMismatch
    )
}

@Test("canonical byte capはexact limitを許可し1 byte超過とoverflowを拒否する")
func codexDeploymentManifestCanonicalByteCapHasExactBoundary() throws {
    let headerBytes = 35 + 4 + 8
    let exactRecordBytes = CodexDeploymentManifestLimits.maximumCanonicalManifestBytes
        - headerBytes

    #expect(
        try CodexDeploymentManifestCanonical.checkedManifestByteCount(
            recordByteCounts: [exactRecordBytes]
        ) == CodexDeploymentManifestLimits.maximumCanonicalManifestBytes
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestCanonical.checkedManifestByteCount(
                recordByteCounts: [exactRecordBytes + 1]
            )
        } == .resourceLimit
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestCanonical.checkedManifestByteCount(
                recordByteCounts: [Int.max]
            )
        } == .resourceLimit
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestCanonical.checkedRecordByteCount(
                pathByteCount: Int.max,
                kind: .file
            )
        } == .resourceLimit
    )
}

@Test("aggregate file byte capはexact limitを許可し1 byte超過とoverflowを拒否する")
func codexDeploymentManifestAggregateByteCapHasExactBoundary() throws {
    let maximum = CodexDeploymentManifestLimits.maximumTotalFileBytes
    #expect(
        try CodexDeploymentManifestResourceBudget.addingFileSize(
            1,
            to: maximum - 1
        ) == maximum
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestResourceBudget.addingFileSize(1, to: maximum)
        } == .resourceLimit
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestResourceBudget.addingFileSize(
                UInt64.max,
                to: 1
            )
        } == .resourceLimit
    )
}
