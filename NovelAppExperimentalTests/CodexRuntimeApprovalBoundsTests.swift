import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("checked arithmeticはexact valueを返しIntとUInt64 overflowを拒否する")
func codexRuntimeApprovalCheckedArithmeticFailsClosed() throws {
    #expect(try CodexRuntimeApprovalCheckedArithmetic.add(UInt64.max - 1, 1) == UInt64.max)
    #expect(
        capturedRuntimeApprovalError {
            _ = try CodexRuntimeApprovalCheckedArithmetic.add(UInt64.max, 1)
        } == .arithmeticOverflow
    )
    #expect(try CodexRuntimeApprovalCheckedArithmetic.add(Int.max - 1, 1) == Int.max)
    #expect(
        capturedRuntimeApprovalError {
            _ = try CodexRuntimeApprovalCheckedArithmetic.add(Int.max, 1)
        } == .arithmeticOverflow
    )
}

@Test("canonical byte capはexact limitを許可し1 byte超過とoverflowを拒否する")
func codexRuntimeApprovalCanonicalByteLimitHasExactBoundary() throws {
    let maximum = CodexRuntimeApprovalLimits.maximumCanonicalBytes
    #expect(
        try CodexRuntimeApprovalCanonical.checkedCanonicalByteCount(
            chunks: [maximum - 1, 1]
        ) == maximum
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try CodexRuntimeApprovalCanonical.checkedCanonicalByteCount(
                chunks: [maximum, 1]
            )
        } == .resourceLimit
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try CodexRuntimeApprovalCanonical.checkedCanonicalByteCount(
                chunks: [Int.max, 1]
            )
        } == .resourceLimit
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try CodexRuntimeApprovalCanonical.checkedCanonicalByteCount(chunks: [-1])
        } == .resourceLimit
    )
}

@Test("単一artifact byte capはexact limitを許可し0または1 byte超過を拒否する")
func codexRuntimeApprovalArtifactByteLimitsHaveExactBoundaries() throws {
    let exactMaximum = CodexRuntimeApprovalLimits.maximumExactArtifactBytes
    #expect(
        try makeRuntimeApprovalNode(byteCount: exactMaximum).executable.byteCount ==
            exactMaximum
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalNode(byteCount: 0)
        } == .invalidByteCount
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalNode(byteCount: exactMaximum + 1)
        } == .invalidByteCount
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalArtifact(
                moduleID: "oversized.exact",
                relativePath: "oversized/exact",
                role: .conditional,
                content: .exactFile(
                    byteCount: exactMaximum + 1,
                    sha256: String(repeating: "a", count: 64)
                )
            )
        } == .invalidByteCount
    )

    let requestMaximum = CodexRuntimeApprovalLimits.maximumRequestDataBytes
    #expect(
        try makeRuntimeApprovalArtifact(
            moduleID: "request.maximum",
            relativePath: "request/maximum",
            role: .requestData,
            content: .boundedRequestData(maximumByteCount: requestMaximum)
        ).content == .boundedRequestData(maximumByteCount: requestMaximum)
    )
    for invalid in [UInt64(0), requestMaximum + 1] {
        #expect(
            capturedRuntimeApprovalError {
                _ = try makeRuntimeApprovalArtifact(
                    moduleID: "request.invalid",
                    relativePath: "request/invalid",
                    role: .requestData,
                    content: .boundedRequestData(maximumByteCount: invalid)
                )
            } == .invalidByteCount
        )
    }
}

@Test("aggregate exact artifact capはexact limitを許可し1 byte超過を拒否する")
func codexRuntimeApprovalAggregateExactBytesHaveExactBoundary() throws {
    let maximum = CodexRuntimeApprovalLimits.maximumTotalExactArtifactBytes
    let perArtifact = CodexRuntimeApprovalLimits.maximumExactArtifactBytes
    let node = try makeRuntimeApprovalNode(byteCount: 1)
    let cli = try makeRuntimeApprovalCLI(byteCount: 1)
    let exactInventory = try aggregateBoundaryInventory(
        nodeByteCount: 1,
        cliByteCount: 1,
        exactSizes: [
            perArtifact,
            perArtifact,
            perArtifact,
            perArtifact - 2
        ]
    )
    let exact = try makeRuntimeApprovalPolicy(
        cli: cli,
        node: node,
        inventory: exactInventory,
        importEdges: []
    )
    #expect(totalExactBytes(exact.inventory) == maximum)

    let overInventory = try aggregateBoundaryInventory(
        nodeByteCount: 1,
        cliByteCount: 1,
        exactSizes: [
            perArtifact,
            perArtifact,
            perArtifact,
            perArtifact - 1
        ]
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(
                cli: cli,
                node: node,
                inventory: overInventory,
                importEdges: []
            )
        } == .resourceLimit
    )
}

@Test("aggregate request capはexact limitを許可し1 artifact追加を拒否する")
func codexRuntimeApprovalAggregateRequestBytesHaveExactBoundary() throws {
    let base = try runtimeApprovalInventory().filter { $0.role != .requestData }
    let perRequest = CodexRuntimeApprovalLimits.maximumRequestDataBytes
    let requests = try (0 ..< 4).map { index in
        try makeRuntimeApprovalArtifact(
            moduleID: "request.\(index)",
            relativePath: "request/\(index)",
            role: .requestData,
            content: .boundedRequestData(maximumByteCount: perRequest)
        )
    }
    let exact = try makeRuntimeApprovalPolicy(
        inventory: base + requests,
        importEdges: []
    )
    #expect(totalRequestBytes(exact.inventory) == CodexRuntimeApprovalLimits.maximumTotalRequestDataBytes)

    let extra = try makeRuntimeApprovalArtifact(
        moduleID: "request.extra",
        relativePath: "request/extra",
        role: .requestData,
        content: .boundedRequestData(maximumByteCount: 1)
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(
                inventory: base + requests + [extra],
                importEdges: []
            )
        } == .resourceLimit
    )
}

@Test("inventory count capはexact件数を許可し1件超過を拒否する")
func codexRuntimeApprovalInventoryCountHasExactBoundary() throws {
    var inventory = try runtimeApprovalInventory()
    let fillerCount = CodexRuntimeApprovalLimits.maximumInventoryCount - inventory.count
    for index in 0 ..< fillerCount {
        try inventory.append(
            makeRuntimeApprovalArtifact(
                moduleID: "filler.\(index)",
                relativePath: "filler/\(index)",
                role: .conditional,
                content: .exactFile(
                    byteCount: 0,
                    sha256: String(repeating: "0", count: 64)
                )
            )
        )
    }
    #expect(inventory.count == CodexRuntimeApprovalLimits.maximumInventoryCount)
    #expect(
        try makeRuntimeApprovalPolicy(inventory: inventory, importEdges: []).inventory.count ==
            CodexRuntimeApprovalLimits.maximumInventoryCount
    )

    let extra = try makeRuntimeApprovalArtifact(
        moduleID: "filler.extra",
        relativePath: "filler/extra",
        role: .conditional,
        content: .exactFile(byteCount: 0, sha256: String(repeating: "0", count: 64))
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(
                inventory: inventory + [extra],
                importEdges: []
            )
        } == .resourceLimit
    )
}

@Test("import edge count capはexact件数を許可し1件超過を拒否する")
func codexRuntimeApprovalImportEdgeCountHasExactBoundary() throws {
    let fixture = try makeImportEdgeBoundaryFixture()
    let inventory = fixture.inventory
    let edges = fixture.edges
    #expect(edges.count == CodexRuntimeApprovalLimits.maximumImportEdgeCount)
    #expect(
        try makeRuntimeApprovalPolicy(
            inventory: inventory,
            importEdges: edges
        ).importEdges.count == CodexRuntimeApprovalLimits.maximumImportEdgeCount
    )

    let extra = try CodexRuntimeImportEdge(
        importerModuleID: "sidecar.entry",
        importedModuleID: "sdk.lazy-source",
        kind: .commonJS
    )
    #expect(
        capturedRuntimeApprovalError {
            _ = try makeRuntimeApprovalPolicy(
                inventory: inventory,
                importEdges: edges + [extra]
            )
        } == .resourceLimit
    )
}
