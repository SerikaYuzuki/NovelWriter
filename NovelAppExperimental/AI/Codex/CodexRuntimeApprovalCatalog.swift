import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex runtime approval must only compile in FUMINIWAExperimental")
#endif

struct CodexApprovedRuntimeIdentity: Sendable, Equatable {
    let policyVersion: UInt32
    let policyGeneration: UInt64
    let policySHA256: String

    private init(policy: CodexRuntimeApprovalPolicy) {
        policyVersion = policy.policyVersion
        policyGeneration = policy.policyGeneration
        policySHA256 = policy.sha256
    }

    enum ProductionCatalog {
        static var approvedPolicyCount: Int {
            approvedPolicies.count
        }

        static func approval(
            matching proposal: CodexRuntimeApprovalProposal
        ) throws -> CodexApprovedRuntimeIdentity {
            guard let policy = approvedPolicies.first(where: {
                constantTimeEqual($0.canonicalBytes, proposal.policy.canonicalBytes)
                    && constantTimeEqual($0.sha256, proposal.policySHA256)
            }) else {
                throw CodexRuntimeApprovalError.approvalUnavailable
            }
            return CodexApprovedRuntimeIdentity(policy: policy)
        }

        /// This list is intentionally empty. Adding an entry requires a reviewed,
        /// compile-time literal; candidate digests and self manifests are not inputs.
        private static let approvedPolicies: [CodexRuntimeApprovalPolicy] = []

        private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
            guard left.count == right.count else { return false }
            var difference: UInt8 = 0
            for (leftByte, rightByte) in zip(left, right) {
                difference |= leftByte ^ rightByte
            }
            return difference == 0
        }

        private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
            constantTimeEqual(Data(left.utf8), Data(right.utf8))
        }
    }
}
