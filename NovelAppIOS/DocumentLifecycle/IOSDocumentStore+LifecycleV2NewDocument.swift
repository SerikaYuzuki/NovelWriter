import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

struct IOSNewDocumentCheckpointContext {
    let candidateWorkID: WorkID
    let candidateCreatedAt: Date
    let application: SyncV2Application
    let expectedSession: WorkspaceSessionToken?
    let expectedWorkID: WorkID?
    let expectedAccountScope: WorkspaceAccountScope
}

extension IOSDocumentStore {
    func checkpointAndInstallNewDocument(
        _ value: NovelDocument,
        context: IOSNewDocumentCheckpointContext
    ) async throws {
        guard !isSyncV2AccountTransitionActive,
              currentDocumentSessionToken == context.expectedSession,
              workspaceModel.activeWorkID == context.expectedWorkID,
              matchesSyncAccount(context.expectedAccountScope) else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        // Keep Work A installed until Work B has committed its first SQLite
        // snapshot. A failed checkpoint leaves the old editor/session intact.
        let result = try await context.application.checkpoint(
            workID: context.candidateWorkID,
            document: value,
            reason: .explicit,
            documentCreatedAt: context.candidateCreatedAt
        )
        guard !isSyncV2AccountTransitionActive,
              currentDocumentSessionToken == context.expectedSession,
              workspaceModel.activeWorkID == context.expectedWorkID,
              matchesSyncAccount(context.expectedAccountScope) else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        // Install is the only point where the active editor/session and recent
        // WorkID move to the candidate.
        guard install(
            value,
            at: libraryRoot,
            attachments: [],
            rememberRecent: false,
            workID: context.candidateWorkID,
            createdAt: context.candidateCreatedAt
        ) else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        applySnapshotSyncV2State(result.state)
        workspaceModel.saveState = .saved
    }
}
