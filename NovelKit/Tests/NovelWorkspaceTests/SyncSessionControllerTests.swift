import Foundation
import NovelSyncV2
@testable import NovelWorkspace
import Testing

@Suite("Shared sync session ownership")
@MainActor
struct SyncSessionControllerTests {
    typealias Controller = SyncSessionController<Bool>

    @Test("operation context rejects every stale identity dimension")
    func currentContext() {
        let workID = WorkID(UUID())
        let session = WorkspaceSessionToken(generation: 1, documentID: UUID(), workID: workID)
        let account = WorkspaceAccountScope(accountID: "A", accountFence: "fence",
                                            serverInstanceID: "server",
                                            protocolEpoch: 2, generation: 3)
        let expected = WorkspaceOperationContext(workID: workID, session: session, account: account, editGeneration: 4)
        #expect(expected.isCurrent(expected))
        #expect(!expected.isCurrent(.init(workID: WorkID(UUID()), session: session, account: account, editGeneration: 4)))
        var newerSession = session
        newerSession.generation += 1
        #expect(!expected.isCurrent(.init(workID: workID, session: newerSession, account: account, editGeneration: 4)))
        newerSession = session
        newerSession.documentID = UUID()
        #expect(!expected.isCurrent(.init(workID: workID, session: newerSession, account: account, editGeneration: 4)))
        newerSession = session
        newerSession.workID = WorkID(UUID())
        #expect(!expected.isCurrent(.init(workID: workID, session: newerSession, account: account, editGeneration: 4)))
        let staleAccounts = [
            WorkspaceAccountScope(accountID: "B", accountFence: account.accountFence,
                                  serverInstanceID: account.serverInstanceID,
                                  protocolEpoch: account.protocolEpoch,
                                  generation: account.generation),
            WorkspaceAccountScope(accountID: account.accountID, accountFence: "other",
                                  serverInstanceID: account.serverInstanceID,
                                  protocolEpoch: account.protocolEpoch,
                                  generation: account.generation),
            WorkspaceAccountScope(accountID: account.accountID, accountFence: account.accountFence,
                                  serverInstanceID: "other",
                                  protocolEpoch: account.protocolEpoch,
                                  generation: account.generation),
            WorkspaceAccountScope(accountID: account.accountID, accountFence: account.accountFence,
                                  serverInstanceID: account.serverInstanceID,
                                  protocolEpoch: 3,
                                  generation: account.generation),
            WorkspaceAccountScope(accountID: account.accountID, accountFence: account.accountFence,
                                  serverInstanceID: account.serverInstanceID,
                                  protocolEpoch: account.protocolEpoch,
                                  generation: account.generation + 1)
        ]
        for stale in staleAccounts {
            #expect(!expected.isCurrent(.init(workID: workID, session: session, account: stale, editGeneration: 4)))
        }
        #expect(!expected.isCurrent(.init(workID: workID, session: session, account: account, editGeneration: 5)))
    }

    @Test("an old completion cannot clear a replacement open or reprojection")
    func staleOwner() {
        let controller = Controller()
        let oldOpen = controller.beginRemoteOnlyOpen(workID: WorkID(UUID()))
        let newWork = WorkID(UUID())
        let newOpen = controller.beginRemoteOnlyOpen(workID: newWork)
        controller.finishRemoteOnlyOpen(owner: oldOpen)
        #expect(controller.remoteOnlyOwner == newOpen)
        #expect(controller.remoteOnlyWorkID == newWork)
        let oldProjection = controller.beginReprojection()
        let newProjection = controller.beginReprojection()
        controller.finishReprojection(owner: oldProjection)
        #expect(controller.reprojectionOwner == newProjection)
    }
}
