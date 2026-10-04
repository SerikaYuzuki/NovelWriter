import Foundation
import NovelSyncV2

/// Installed payload identity, distinct from the synchronization gate's token.
public struct WorkspaceSessionToken: Hashable, Sendable {
    public var generation: UInt64
    public var documentID: UUID
    public var workID: WorkID

    public init(generation: UInt64, documentID: UUID, workID: WorkID) {
        self.generation = generation
        self.documentID = documentID
        self.workID = workID
    }
}

/// Token refresh preserves this scope. Every invalidation advances generation,
/// rejecting older completions even when the binding itself is unchanged.
public struct WorkspaceAccountScope: Hashable, Sendable {
    public let accountID: String?
    public let accountFence: String?
    public let serverInstanceID: String?
    public let protocolEpoch: Int64?
    public let generation: UInt64

    public init(accountID: String?, accountFence: String?, serverInstanceID: String?, protocolEpoch: Int64?, generation: UInt64) {
        self.accountID = accountID
        self.accountFence = accountFence
        self.serverInstanceID = serverInstanceID
        self.protocolEpoch = protocolEpoch
        self.generation = generation
    }
}

public struct WorkspaceOperationContext: Sendable {
    public let workID: WorkID?
    public let session: WorkspaceSessionToken?
    public let account: WorkspaceAccountScope
    public let editGeneration: UInt64?

    public init(workID: WorkID?, session: WorkspaceSessionToken?, account: WorkspaceAccountScope, editGeneration: UInt64?) {
        self.workID = workID
        self.session = session
        self.account = account
        self.editGeneration = editGeneration
    }

    public func isCurrent(_ current: Self) -> Bool {
        workID == current.workID && session == current.session
            && account == current.account && editGeneration == current.editGeneration
    }
}
