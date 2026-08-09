@testable import FUMINIWAExperimental
import Testing

@Test("production approval catalogは空で実行authorityを発行しない")
func codexRuntimeProductionApprovalCatalogIsFailClosed() throws {
    let proposal = try CodexRuntimeApprovalProposal(policy: makeRuntimeApprovalPolicy())

    #expect(CodexApprovedRuntimeIdentity.ProductionCatalog.approvedPolicyCount == 0)
    #expect(
        capturedRuntimeApprovalError {
            _ = try CodexApprovedRuntimeIdentity.ProductionCatalog.approval(
                matching: proposal
            )
        } == .approvalUnavailable
    )
}

@Test("candidateとself manifest相当のdigestが一致してもproposalはauthorityではない")
func codexRuntimeCandidateCannotPromoteItselfToAuthority() throws {
    let policy = try makeRuntimeApprovalPolicy(
        deploymentRootSHA256: runtimeApprovalDeploymentSHA256
    )
    let candidate = CodexRuntimeApprovalProposal(policy: policy)

    #expect(candidate.policy.deploymentRootSHA256 == runtimeApprovalDeploymentSHA256)
    #expect(candidate.policySHA256 == policy.sha256)
    #expect(CodexApprovedRuntimeIdentity.ProductionCatalog.approvedPolicyCount == 0)
    #expect(
        capturedRuntimeApprovalError {
            _ = try CodexApprovedRuntimeIdentity.ProductionCatalog.approval(
                matching: candidate
            )
        } == .approvalUnavailable
    )
}

@Test("production authorityの失敗はpathや候補値を含まない固定errorだけを返す")
func codexRuntimeApprovalFailureIsTypedAndRedacted() throws {
    let proposal = try CodexRuntimeApprovalProposal(policy: makeRuntimeApprovalPolicy())
    do {
        _ = try CodexApprovedRuntimeIdentity.ProductionCatalog.approval(matching: proposal)
        Issue.record("expected approval failure")
    } catch let error as CodexRuntimeApprovalError {
        #expect(error == .approvalUnavailable)
        #expect(error.rawValue == "approval_unavailable")
        #expect(!error.rawValue.contains("/"))
        #expect(!error.rawValue.contains(runtimeApprovalDeploymentSHA256))
    }
}
