import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import NovelWritingSupport

/// Explicit-send capability. HTTP, credentials and platform lifecycle remain in app composition.
@MainActor
public protocol WorkspaceWritingHost: WorkspaceEditorHost {
    var writingInteractionAllowed: Bool { get }
    var writingApplication: SyncV2Application? { get }
    var userDefaults: UserDefaults { get }
    var workspaceModel: WorkspaceModel { get }
    var writingSyncScheduler: WritingSyncScheduler { get }
    var documentOperationGate: DocumentOperationGate { get }
    func writingAttachments() throws -> [WritingAttachment]
    func installWritingMutation(_ document: NovelDocument, attachments: [WritingAttachment]) throws
    func saveWritingChanges() async -> Bool
}
