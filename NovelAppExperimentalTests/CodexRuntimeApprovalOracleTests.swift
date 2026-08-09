import Foundation
@testable import FUMINIWAExperimental
import Testing

private let runtimeApprovalOracleSHA256 =
    "0498758039db7668c97ada8a0cb1a31e44cdbef844acc5b3e77f4d50b01912b2"

/// Generated once with an independent Node binary-layout encoder, not the Swift
/// production writer. Keeping the full bytes literal makes layout drift visible.
private let runtimeApprovalOracleBase64 = [
    "RlVNSU5JV0EtQ09ERVgtUlVOVElNRS1BUFBST1ZBTAAAAAABAAAAAAAAAAcAAAAHMC4xNDcuMBERERERERERERERERERERER",
    "EREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREREAAAAHMC4xNDcuMCIiIiIiIiIiIiIiIiIi",
    "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIAAAAUMC4xNDcuMC1kYXJ3aW4tYXJt",
    "NjQzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzAAAAQm5v",
    "ZGVfbW9kdWxlcy9Ab3BlbmFpL2NvZGV4L3ZlbmRvci9hYXJjaDY0LWFwcGxlLWRhcndpbi9jb2RleC9jb2RleAAAAAAA1Z+A",
    "ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZ3d3d3d3d3d3d3d3d3d3d3d3d3dwAAAAh2MjIuMjMuMQEAAAAVcnVu",
    "dGltZS9ub2RlL2Jpbi9ub2RlAAAAAAKA3oBERERERERERERERERERERERERERERERERERERERERERFVVVVVVVVVVVVVVVVVV",
    "VVVVVVVVAAAAAYiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIAAAACggAAAAOYW1iaWVudC5wbHVnaW4AAAAOYW1i",
    "aWVudC9wbHVnaW4EBwAAAA5hcHBsZS5zZWN1cml0eQAAACJvcy9hcHBsZS1zZWFsZWQvU2VjdXJpdHkuZnJhbWV3b3JrAwMA",
    "AAAJY29kZXguY2xpAAAAQm5vZGVfbW9kdWxlcy9Ab3BlbmFpL2NvZGV4L3ZlbmRvci9hYXJjaDY0LWFwcGxlLWRhcndpbi9j",
    "b2RleC9jb2RleAEAAAAAANWfgGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmAwAAAAxub2RlLnJ1bnRpbWUAAAAV",
    "cnVudGltZS9ub2RlL2Jpbi9ub2RlAQAAAAACgN6AREREREREREREREREREREREREREREREREREREREREREQFAAAADHBhY2th",
    "Z2UubG9jawAAABFwYWNrYWdlLWxvY2suanNvbgEAAAAAAAAB+d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3dBgAA",
    "AA9yZXF1ZXN0LnBheWxvYWQAAAAPcmVxdWVzdC9wYXlsb2FkAgAAAAAACAAAAQAAAApzZGsuYnVuZGxlAAAALG5vZGVfbW9k",
    "dWxlcy9Ab3BlbmFpL2NvZGV4LXNkay9kaXN0L2luZGV4LmpzAQAAAAAAAADKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
    "qqqqqqoEAAAAD3Nkay5sYXp5LXNvdXJjZQAAACtub2RlX21vZHVsZXMvQG9wZW5haS9jb2RleC1zZGsvZGlzdC9sYXp5Lmpz",
    "AQAAAAAAAAGUzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMwCAAAAC3Nkay5wYWNrYWdlAAAAK25vZGVfbW9kdWxl",
    "cy9Ab3BlbmFpL2NvZGV4LXNkay9wYWNrYWdlLmpzb24BAAAAAAAAAS+7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7",
    "uwEAAAANc2lkZWNhci5lbnRyeQAAABBzaWRlY2FyL21haW4ubWpzAQAAAAAAAABlmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZ",
    "mZmZmZmZmZkAAAAEBQAAAApzZGsuYnVuZGxlAAAACWNvZGV4LmNsaQIAAAAKc2RrLmJ1bmRsZQAAAA9zZGsubGF6eS1zb3Vy",
    "Y2UGAAAACnNkay5idW5kbGUAAAALc2RrLnBhY2thZ2UBAAAADXNpZGVjYXIuZW50cnkAAAAKc2RrLmJ1bmRsZQ=="
].joined()

@Test("approval policy canonical bytesとdigestは独立した固定oracleに一致する")
func codexRuntimeApprovalMatchesIndependentCanonicalOracle() throws {
    let policy = try makeRuntimeApprovalPolicy()

    #expect(policy.canonicalBytes.count == 1504)
    #expect(policy.canonicalBytes.base64EncodedString() == runtimeApprovalOracleBase64)
    #expect(policy.sha256 == runtimeApprovalOracleSHA256)
    #expect(policy.sha256.utf8.count == 64)

    let repeated = try makeRuntimeApprovalPolicy(
        inventory: runtimeApprovalInventory().reversed(),
        importEdges: runtimeApprovalImportEdges().reversed()
    )
    #expect(repeated.canonicalBytes == policy.canonicalBytes)
    #expect(repeated.sha256 == policy.sha256)
}

@Test("review対象fieldまたはedge kindの1 byte差はcanonical identityを変える")
func codexRuntimeApprovalCanonicalIdentityBindsEveryReviewedValue() throws {
    let baseline = try makeRuntimeApprovalPolicy()
    let changedRoot = try makeRuntimeApprovalPolicy(
        deploymentRootSHA256: String(repeating: "f", count: 64)
    )
    #expect(changedRoot.canonicalBytes != baseline.canonicalBytes)
    #expect(changedRoot.sha256 != baseline.sha256)

    var edges = try runtimeApprovalImportEdges()
    edges[0] = try CodexRuntimeImportEdge(
        importerModuleID: "sidecar.entry",
        importedModuleID: "sdk.bundle",
        kind: .commonJS
    )
    let changedEdge = try makeRuntimeApprovalPolicy(importEdges: edges)
    #expect(changedEdge.canonicalBytes != baseline.canonicalBytes)
    #expect(changedEdge.sha256 != baseline.sha256)
}

@Test("canonical identity bytesへsecret・local absolute path・原稿内容を含めない")
func codexRuntimeApprovalCanonicalBytesContainOnlyContentFreeIdentity() throws {
    let canonical = try makeRuntimeApprovalPolicy().canonicalBytes
    let forbiddenCanaries = [
        "sk-test-secret-value",
        "/Users/recky/",
        "/home/recky/",
        ".novelpkg",
        "これは実原稿本文です。",
        "selected_text",
        "application_prompt",
        "application_response",
        "request-id-00000000"
    ]
    for canary in forbiddenCanaries {
        #expect(!canonical.contains(Data(canary.utf8)))
    }

    #expect(canonical.contains(Data("v22.23.1".utf8)))
    #expect(canonical.contains(Data("sdk.bundle".utf8)))
    #expect(canonical.contains(Data("request.payload".utf8)))
}

@Test("proposalはpolicy bytesを複製せず同じcontent-free digestだけを参照する")
func codexRuntimeApprovalProposalPreservesReviewedPolicyIdentity() throws {
    let policy = try makeRuntimeApprovalPolicy()
    let proposal = CodexRuntimeApprovalProposal(policy: policy)

    #expect(proposal.policy.canonicalBytes == policy.canonicalBytes)
    #expect(proposal.policySHA256 == runtimeApprovalOracleSHA256)
    #expect(proposal.policySHA256 == policy.sha256)
}
