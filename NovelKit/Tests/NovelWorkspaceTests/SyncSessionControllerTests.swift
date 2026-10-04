import Foundation
import NovelSyncV2
@testable import NovelWorkspace
import Testing

@Suite("Shared sync session ownership")
@MainActor
struct SyncSessionControllerTests {
    typealias Controller = SyncSessionController<Int, String, Bool>

    @Test("operation context rejects every stale identity dimension")
    func currentContext() {
        let workID = WorkID(UUID())
        let expected = Controller.OperationContext(workID: workID, session: 1, account: "A", editGeneration: 4)
        #expect(expected.isCurrent(expected))
        #expect(!expected.isCurrent(.init(workID: WorkID(UUID()), session: 1, account: "A", editGeneration: 4)))
        #expect(!expected.isCurrent(.init(workID: workID, session: 2, account: "A", editGeneration: 4)))
        #expect(!expected.isCurrent(.init(workID: workID, session: 1, account: "B", editGeneration: 4)))
        #expect(!expected.isCurrent(.init(workID: workID, session: 1, account: "A", editGeneration: 5)))
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
