@testable import FUMINIWAExperimental
import Testing

@Test("synthetic approval contractは全inventory partitionを区別して検証する")
func codexRuntimeApprovalValidatesEveryInventoryPartition() throws {
    let policy = try makeRuntimeApprovalPolicy()
    let byRole = Dictionary(grouping: policy.inventory, by: \CodexRuntimeInventoryArtifact.role)

    #expect(policy.policyVersion == 1)
    #expect(policy.policyGeneration == 7)
    #expect(Set(byRole.keys) == Set(CodexRuntimeInventoryRole.allCases))
    #expect(byRole[.evaluatedSource]?.count == 2)
    for role in CodexRuntimeInventoryRole.allCases where role != .evaluatedSource {
        #expect(byRole[role]?.count == (role == .executable ? 2 : 1))
    }

    for artifact in policy.inventory {
        switch (artifact.role, artifact.content) {
        case (.evaluatedSource, .exactFile),
             (.resolutionMetadata, .exactFile),
             (.executable, .exactFile),
             (.conditional, .exactFile),
             (.provenance, .exactFile),
             (.requestData, .boundedRequestData),
             (.operatingSystemTrust, .operatingSystemProvided),
             (.forbidden, .forbidden):
            break
        default:
            Issue.record("role and content identity were collapsed")
        }
    }
}

@Test("inventoryとimport edgeは入力順でなくunsigned UTF-8 key順へ正規化する")
func codexRuntimeApprovalCanonicalizesInventoryAndEdges() throws {
    let inventory = try runtimeApprovalInventory()
    let edges = try runtimeApprovalImportEdges()
    let policy = try makeRuntimeApprovalPolicy(
        inventory: inventory.reversed(),
        importEdges: edges.reversed()
    )

    #expect(policy.inventory.map(\.moduleID) == [
        "ambient.plugin",
        "apple.security",
        "codex.cli",
        "node.runtime",
        "package.lock",
        "request.payload",
        "sdk.bundle",
        "sdk.lazy-source",
        "sdk.package",
        "sidecar.entry"
    ])
    #expect(policy.importEdges.map { edge in
        "\(edge.importerModuleID)>\(edge.importedModuleID)>\(edge.kind.rawValue)"
    } == [
        "sdk.bundle>codex.cli>5",
        "sdk.bundle>sdk.lazy-source>2",
        "sdk.bundle>sdk.package>6",
        "sidecar.entry>sdk.bundle>1"
    ])

    let original = try makeRuntimeApprovalPolicy()
    #expect(policy.canonicalBytes == original.canonicalBytes)
    #expect(policy.sha256 == original.sha256)
}

@Test("duplicate module IDとpathを別々に拒否する")
func codexRuntimeApprovalRejectsDuplicateInventoryKeys() throws {
    let inventory = try runtimeApprovalInventory()
    let duplicateID = try makeRuntimeApprovalArtifact(
        moduleID: inventory[0].moduleID,
        relativePath: "sidecar/duplicate.mjs",
        role: inventory[1].role,
        content: inventory[1].content
    )
    #expect(
        policyError(inventory: replacing(inventory, at: 1, with: duplicateID)) ==
            .duplicateModuleID
    )

    let duplicatePath = try makeRuntimeApprovalArtifact(
        moduleID: "sdk.package-copy",
        relativePath: inventory[0].relativePath,
        role: inventory[1].role,
        content: inventory[1].content
    )
    #expect(
        policyError(inventory: replacing(inventory, at: 1, with: duplicatePath)) ==
            .duplicatePath
    )
}

@Test("全roleの明示を要求しcontent identityのrole横断を拒否する")
func codexRuntimeApprovalRejectsMissingAndConflictingRoles() throws {
    let inventory = try runtimeApprovalInventory()
    #expect(
        policyError(inventory: inventory.filter { $0.role != .forbidden }) ==
            .missingInventoryRole
    )

    let conflicts: [(CodexRuntimeInventoryRole, CodexRuntimeArtifactContentIdentity)] = [
        (.evaluatedSource, .boundedRequestData(maximumByteCount: 1)),
        (.resolutionMetadata, .operatingSystemProvided),
        (.executable, .forbidden),
        (.conditional, .boundedRequestData(maximumByteCount: 1)),
        (.provenance, .operatingSystemProvided),
        (.requestData, .exactFile(byteCount: 1, sha256: String(repeating: "a", count: 64))),
        (.operatingSystemTrust, .exactFile(
            byteCount: 1,
            sha256: String(repeating: "a", count: 64)
        )),
        (.forbidden, .operatingSystemProvided)
    ]
    for (role, content) in conflicts {
        #expect(
            capturedRuntimeApprovalError {
                _ = try makeRuntimeApprovalArtifact(
                    moduleID: "conflict.test",
                    relativePath: "conflict/test",
                    role: role,
                    content: content
                )
            } == .invalidArtifactContent
        )
    }
}

@Test("NodeとCLI executable identityはinventory exact bytesと一致を要求する")
func codexRuntimeApprovalRejectsExecutableInventoryMismatch() throws {
    let inventory = try runtimeApprovalInventory()
    let nodeIndex = try #require(
        inventory.firstIndex(where: { $0.moduleID == "node.runtime" })
    )
    let mismatchedNode = try makeRuntimeApprovalArtifact(
        moduleID: "node.runtime",
        relativePath: runtimeApprovalNodePath,
        role: .executable,
        content: .exactFile(
            byteCount: runtimeApprovalNodeByteCount,
            sha256: String(repeating: "e", count: 64)
        )
    )

    #expect(
        policyError(inventory: replacing(inventory, at: nodeIndex, with: mismatchedNode)) ==
            .executableIdentityMismatch
    )
}

@Test("import graphはduplicate・unknown・self・forbidden・role不一致を拒否する")
func codexRuntimeApprovalRejectsInvalidImportGraph() throws {
    let edges = try runtimeApprovalImportEdges()
    #expect(policyError(importEdges: edges + [edges[0]]) == .duplicateImportEdge)

    let unknown = try CodexRuntimeImportEdge(
        importerModuleID: "sdk.bundle",
        importedModuleID: "unknown.module",
        kind: .staticESM
    )
    #expect(policyError(importEdges: edges + [unknown]) == .unknownImportEndpoint)

    let selfEdge = try CodexRuntimeImportEdge(
        importerModuleID: "sdk.bundle",
        importedModuleID: "sdk.bundle",
        kind: .staticESM
    )
    #expect(policyError(importEdges: edges + [selfEdge]) == .invalidImportEdge)

    let invalidImporter = try CodexRuntimeImportEdge(
        importerModuleID: "package.lock",
        importedModuleID: "sdk.bundle",
        kind: .staticESM
    )
    #expect(policyError(importEdges: edges + [invalidImporter]) == .invalidImportEdge)

    let forbiddenTarget = try CodexRuntimeImportEdge(
        importerModuleID: "sdk.bundle",
        importedModuleID: "ambient.plugin",
        kind: .dynamicESM
    )
    #expect(policyError(importEdges: edges + [forbiddenTarget]) == .invalidImportEdge)

    let wrongKind = try CodexRuntimeImportEdge(
        importerModuleID: "sdk.bundle",
        importedModuleID: "sdk.package",
        kind: .staticESM
    )
    #expect(policyError(importEdges: edges + [wrongKind]) == .invalidImportEdge)

    let provenanceRead = try CodexRuntimeImportEdge(
        importerModuleID: "sdk.bundle",
        importedModuleID: "package.lock",
        kind: .runtimeDataRead
    )
    #expect(policyError(importEdges: edges + [provenanceRead]) == .invalidImportEdge)
}

@Test("conditional artifactは全import kindを用途付きで明示分類できる")
func codexRuntimeApprovalClassifiesEveryConditionalImportKind() throws {
    let edges = try CodexRuntimeImportKind.allCases.map { kind in
        try CodexRuntimeImportEdge(
            importerModuleID: "sdk.bundle",
            importedModuleID: "sdk.lazy-source",
            kind: kind
        )
    }
    let policy = try makeRuntimeApprovalPolicy(importEdges: edges)

    #expect(policy.importEdges.count == CodexRuntimeImportKind.allCases.count)
    #expect(Set(policy.importEdges.map(\.kind)) == Set(CodexRuntimeImportKind.allCases))
    #expect(
        policy.importEdges.allSatisfy {
            $0.importedModuleID == "sdk.lazy-source"
        }
    )
}

private func replacing(
    _ inventory: [CodexRuntimeInventoryArtifact],
    at index: Int,
    with artifact: CodexRuntimeInventoryArtifact
) -> [CodexRuntimeInventoryArtifact] {
    var result = inventory
    result[index] = artifact
    return result
}

private func policyError(
    inventory: [CodexRuntimeInventoryArtifact]? = nil,
    importEdges: [CodexRuntimeImportEdge]? = nil
) -> CodexRuntimeApprovalError? {
    capturedRuntimeApprovalError {
        _ = try makeRuntimeApprovalPolicy(
            inventory: inventory,
            importEdges: importEdges
        )
    }
}
