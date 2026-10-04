import EditorKit
import Foundation
import NovelCore
import NovelSyncV2Application
import NovelWorkspace
import NovelWorkspaceUI
import NovelWritingSupport
import Testing

@MainActor
private final class FakeWritingHost: WorkspaceWritingHost {
    var document = NovelDocument(title: "作品", chapters: [Chapter(title: "章", episodes: [Episode(title: "話", content: "保存済み")])])
    var operationContext: WorkspaceOperationContext {
        WorkspaceOperationContext(workID: nil, session: nil,
                                  account: WorkspaceAccountScope(accountID: nil, accountFence: nil, serverInstanceID: nil,
                                                                 protocolEpoch: nil, generation: 0), editGeneration: nil)
    }

    var permitsLocalMutation = true
    var writingInteractionAllowed = true
    var writingApplication: SyncV2Application? {
        nil
    }

    let userDefaults = UserDefaults()
    let assistantRequestCenter = AssistantRequestCenter()
    let writingSyncScheduler = WritingSyncScheduler()
    let documentOperationGate = DocumentOperationGate()
    let editorCommandSession = EditorCommandSession()
    var selectedChapterID: ChapterID? {
        document.chapters.first?.id
    }

    var selectedEpisodeID: EpisodeID? {
        document.chapters.first?.episodes.first?.id
    }

    var committedText: EditorCommittedTextCaptureResult = .notActive
    var resources: [WritingAttachment] = []
    var mutations = 0
    func captureCommittedText() -> EditorCommittedTextCaptureResult {
        committedText
    }

    func writingAttachments() throws -> [WritingAttachment] {
        resources
    }

    func installWritingMutation(_: NovelDocument, attachments _: [WritingAttachment]) throws {
        mutations += 1
    }

    func saveWritingChanges() async -> Bool {
        mutations += 1; return true
    }

    func markChanged(policy _: WorkspaceSavePolicy) {
        mutations += 1
    }

    func applyOwnerRemoval(_: NovelDocument) {
        mutations += 1
    }

    func markWritingDocumentChanged() {
        mutations += 1
    }

    func invalidateEditorContent() {
        mutations += 1
    }

    func applyUncountedProofreading(expectedText _: String, replacement _: String) -> Bool {
        mutations += 1; return true
    }
}

@MainActor
struct WritingAssistantHostFactoryTests {
    @Test func captureUsesPortTextWithoutSaving() throws {
        let host = FakeWritingHost(), work = UUID()
        host.committedText = .captured("未保存の確定本文")
        host.resources = [WritingAttachment(id: UUID(), fileName: "reference.txt", bytes: Data("資料".utf8))]
        let capture = try WritingAssistantHostFactory.capture(host: host, workUUID: work)
        #expect(capture.workId == work)
        #expect(capture.document.chapters[0].episodes[0].content == "未保存の確定本文")
        #expect(host.document.chapters[0].episodes[0].content == "保存済み")
        #expect(capture.attachments.count == 1)
        #expect(capture.attachments.first?.fileName == "reference.txt")
        #expect(host.mutations == 0)
    }

    @Test func compositionAndUnavailableInteractionNeverCaptureOrMutate() throws {
        let host = FakeWritingHost()
        host.committedText = .compositionInProgress
        #expect(throws: AssistantError.self) { try WritingAssistantHostFactory.capture(host: host, workUUID: UUID()) }
        host.committedText = .captured("確定本文")
        host.writingInteractionAllowed = false
        #expect(throws: WritingError.self) { try WritingAssistantHostFactory.capture(host: host, workUUID: UUID()) }
        #expect(host.mutations == 0)
    }
}
