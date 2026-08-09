@testable import FUMINIWAExperimental

struct ImportEdgeBoundaryFixture {
    let inventory: [CodexRuntimeInventoryArtifact]
    let edges: [CodexRuntimeImportEdge]
}

func makeImportEdgeBoundaryFixture() throws -> ImportEdgeBoundaryFixture {
    let importers = try makeConditionalArtifacts(
        namespace: "edge.importer",
        pathNamespace: "edge/importer",
        sha256: String(repeating: "1", count: 64)
    )
    let imported = try makeConditionalArtifacts(
        namespace: "edge.imported",
        pathNamespace: "edge/imported",
        sha256: String(repeating: "2", count: 64)
    )
    let edges = try importers.flatMap { importer in
        try imported.map { target in
            try CodexRuntimeImportEdge(
                importerModuleID: importer.moduleID,
                importedModuleID: target.moduleID,
                kind: .dynamicESM
            )
        }
    }
    return try ImportEdgeBoundaryFixture(
        inventory: runtimeApprovalInventory() + importers + imported,
        edges: edges
    )
}

func makeConditionalArtifacts(
    namespace: String,
    pathNamespace: String,
    sha256: String
) throws -> [CodexRuntimeInventoryArtifact] {
    try (0 ..< 128).map { index in
        try makeRuntimeApprovalArtifact(
            moduleID: "\(namespace).\(index)",
            relativePath: "\(pathNamespace)/\(index)",
            role: .conditional,
            content: .exactFile(byteCount: 0, sha256: sha256)
        )
    }
}

func aggregateBoundaryInventory(
    nodeByteCount: UInt64,
    cliByteCount: UInt64,
    exactSizes: [UInt64]
) throws -> [CodexRuntimeInventoryArtifact] {
    let exactArtifacts = try aggregateExactArtifacts(exactSizes)
    let boundaryArtifacts = try aggregateBoundaryArtifacts(
        nodeByteCount: nodeByteCount,
        cliByteCount: cliByteCount
    )
    return exactArtifacts + boundaryArtifacts
}

func aggregateExactArtifacts(
    _ exactSizes: [UInt64]
) throws -> [CodexRuntimeInventoryArtifact] {
    let roles: [CodexRuntimeInventoryRole] = [
        .evaluatedSource,
        .resolutionMetadata,
        .conditional,
        .provenance
    ]
    return try zip(roles, exactSizes).enumerated().map { index, pair in
        try makeRuntimeApprovalArtifact(
            moduleID: "aggregate.\(index)",
            relativePath: "aggregate/\(index)",
            role: pair.0,
            content: .exactFile(
                byteCount: pair.1,
                sha256: String(repeating: "a", count: 64)
            )
        )
    }
}

func aggregateBoundaryArtifacts(
    nodeByteCount: UInt64,
    cliByteCount: UInt64
) throws -> [CodexRuntimeInventoryArtifact] {
    let executables = try aggregateExecutableArtifacts(
        nodeByteCount: nodeByteCount,
        cliByteCount: cliByteCount
    )
    let partitions = try aggregateNonFilePartitions()
    return executables + partitions
}

func aggregateExecutableArtifacts(
    nodeByteCount: UInt64,
    cliByteCount: UInt64
) throws -> [CodexRuntimeInventoryArtifact] {
    try [
        makeRuntimeApprovalArtifact(
            moduleID: "node.runtime",
            relativePath: runtimeApprovalNodePath,
            role: .executable,
            content: .exactFile(
                byteCount: nodeByteCount,
                sha256: runtimeApprovalNodeSHA256
            )
        ),
        makeRuntimeApprovalArtifact(
            moduleID: "codex.cli",
            relativePath: runtimeApprovalCLIPath,
            role: .executable,
            content: .exactFile(
                byteCount: cliByteCount,
                sha256: runtimeApprovalCLISHA256
            )
        )
    ]
}

func aggregateNonFilePartitions() throws -> [CodexRuntimeInventoryArtifact] {
    try [
        makeRuntimeApprovalArtifact(
            moduleID: "request.payload",
            relativePath: "request/payload",
            role: .requestData,
            content: .boundedRequestData(maximumByteCount: 1)
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

func totalExactBytes(_ inventory: [CodexRuntimeInventoryArtifact]) -> UInt64 {
    inventory.reduce(into: 0) { total, artifact in
        if case let .exactFile(byteCount, _) = artifact.content {
            total += byteCount
        }
    }
}

func totalRequestBytes(_ inventory: [CodexRuntimeInventoryArtifact]) -> UInt64 {
    inventory.reduce(into: 0) { total, artifact in
        if case let .boundedRequestData(maximumByteCount) = artifact.content {
            total += maximumByteCount
        }
    }
}
