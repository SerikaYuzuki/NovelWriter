import Foundation
import NovelCore
import NovelSyncV2
import NovelWorkspace

@MainActor
final class FakeWorkspaceHost: WorkspaceAttachmentHost {
    var workspaceAttachments = WorkspaceAttachmentSet()
    var document = NovelDocument.newDocument()
    var session: WorkspaceSessionToken
    var permitsLocalMutation = true
    var policies: [WorkspaceSavePolicy] = []
    var ownerRemovals: [NovelDocument] = []
    var markedDocuments: [NovelDocument] = []

    init() {
        session = WorkspaceSessionToken(generation: 1, documentID: document.id, workID: WorkID(UUID()))
    }

    var operationContext: WorkspaceOperationContext {
        WorkspaceOperationContext(workID: session.workID, session: session,
                                  account: WorkspaceAccountScope(accountID: nil, accountFence: nil,
                                                                 serverInstanceID: nil, protocolEpoch: nil,
                                                                 generation: 0),
                                  editGeneration: nil)
    }

    func installWorkspaceAttachments(_ replacement: WorkspaceAttachmentSet) {
        workspaceAttachments = replacement
    }

    func markChanged(policy: WorkspaceSavePolicy) {
        policies.append(policy)
        markedDocuments.append(document)
    }

    func applyOwnerRemoval(_ replacement: NovelDocument) {
        ownerRemovals.append(replacement)
        WorkspaceAttachmentCommands.applyOwnerRemoval(replacement, host: self)
    }
}
