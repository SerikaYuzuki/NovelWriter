import Foundation
import NovelCore
import NovelWorkspace
import NovelWorkspaceUI

extension Notification.Name {
    static let toggleWritingInspector = Notification.Name("dev.serikayuzuki.fuminiwa.toggleWritingInspector")
    static let presentChapterTitleEditor = Notification.Name("dev.serikayuzuki.fuminiwa.presentChapterTitleEditor")
    static let presentChapterMemo = Notification.Name("dev.serikayuzuki.fuminiwa.presentChapterMemo")
    static let presentAttachmentImporter = Notification.Name("dev.serikayuzuki.fuminiwa.presentAttachmentImporter")
    static let presentWorkHistory = Notification.Name("dev.serikayuzuki.fuminiwa.presentWorkHistory")
    static let presentSnapshotSyncConflict = Notification.Name("dev.serikayuzuki.fuminiwa.presentSnapshotSyncConflict")
}

/// macOSの作品操作をv2のWorkID sessionとDocumentOperationGateへ集約する。
///
/// ここではパッケージURLを通常保存のidentityにしない。パッケージcodecを呼ぶのは
/// 明示的な取り込み／書き出しだけで、編集・選択・自動保存はSQLite checkpointへ
/// 委譲する。
extension AppState {
    var supportsAttachments: Bool {
        snapshotSyncV2Application != nil
    }

    func flushSaveImmediately() {
        Task { @MainActor [weak self] in
            _ = await self?.saveNow()
        }
    }

    func permitsEditorSynchronization(expectedSession: WorkspaceSessionToken?) -> Bool {
        permitsDocumentInteraction && (expectedSession == nil || expectedSession == workspaceModel.documentSessionToken)
    }

    func permitsMutation(expectedSession: WorkspaceSessionToken?) -> Bool {
        permitsEditorSynchronization(expectedSession: expectedSession)
    }

    func setSelection(chapterID: ChapterID?, episodeID: EpisodeID?) {
        outlineCommands().setSelection(chapterID: chapterID, episodeID: episodeID)
    }

    func preferredEpisodeID(in chapterID: ChapterID) -> EpisodeID? {
        workspaceModel.document.chapters.first(where: { $0.id == chapterID })?.episodes.first?.id
    }

    func normalizedChapterTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の章" : trimmed
    }

    func normalizedEpisodeTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の話" : trimmed
    }

    static func nilIfBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func selectProjectSectionAfterTransition(_ section: ProjectSection) async -> Bool {
        await EpisodeTransition(host: self).perform(saveAfter: true) {
            self.workspaceSelection = WorkspaceSelection(section: section)
            if section == .worldbuilding {
                self.ensureWorldNoteSelection()
            }
            return true
        }
    }

    func selectEpisodeAfterTransition(_ episodeID: EpisodeID, in chapterID: ChapterID) async -> Bool {
        await EpisodeTransition(host: self).perform(saveAfter: true) {
            self.outlineCommands(prepared: true).selectEpisode(episodeID, in: chapterID)
        }
    }

    func selectChapterAfterTransition(_ chapterID: ChapterID) async -> Bool {
        await EpisodeTransition(host: self).perform(saveAfter: true) {
            self.workspaceModel.document.chapters.contains(where: { $0.id == chapterID }) && self.outlineCommands(prepared: true).selectChapter(chapterID)
        }
    }

    func addChapterAfterTransition() async -> Bool {
        guard permitsDocumentChoice else { return false }
        return await EpisodeTransition(host: self).perform(saveAfter: true) {
            self.outlineCommands(prepared: true).addChapter()
        }
    }

    func addEpisodeAfterTransition(to chapterID: ChapterID? = nil) async -> Bool {
        guard permitsDocumentChoice else { return false }
        let targetChapterID = chapterID ?? workspaceModel.selectedChapterID
        return await EpisodeTransition(host: self).perform(saveAfter: true) {
            self.outlineCommands(prepared: true).addEpisode(to: targetChapterID)
        }
    }

    func deleteChapterAfterTransition(
        id: ChapterID,
        expectedSession: WorkspaceSessionToken
    ) async -> Bool {
        await EpisodeTransition(host: self).perform(saveAfter: true, expectedSession: expectedSession) {
            self.outlineCommands(prepared: true).deleteChapter(id, expectedSession: expectedSession)
        }
    }

    func deleteEpisodeAfterTransition(
        id: EpisodeID,
        from chapterID: ChapterID,
        expectedSession: WorkspaceSessionToken
    ) async -> Bool {
        await EpisodeTransition(host: self).perform(saveAfter: true, expectedSession: expectedSession) {
            self.outlineCommands(prepared: true).deleteEpisodes([id], in: chapterID, expectedSession: expectedSession)
        }
    }

    func moveChaptersAfterTransition(fromOffsets: IndexSet, toOffset: Int) async {
        let order = workspaceModel.document.chapters.map(\.id)
        _ = await EpisodeTransition(host: self).perform(saveAfter: true) {
            guard self.workspaceModel.document.chapters.map(\.id) == order else { return false }
            self.outlineCommands(prepared: true).moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
            return true
        }
    }

    func moveEpisodesAfterTransition(
        in chapterID: ChapterID,
        fromOffsets: IndexSet,
        toOffset: Int
    ) async {
        let order = workspaceModel.document.chapters.first(where: { $0.id == chapterID })?.episodes.map(\.id)
        _ = await EpisodeTransition(host: self).perform(saveAfter: true) {
            guard self.workspaceModel.document.chapters.first(where: { $0.id == chapterID })?.episodes.map(\.id) == order else { return false }
            self.outlineCommands(prepared: true).moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
            return true
        }
    }

    func moveEpisodeAfterTransition(
        id episodeID: EpisodeID,
        from sourceChapterID: ChapterID,
        to destinationChapterID: ChapterID,
        before targetEpisodeID: EpisodeID? = nil
    ) async -> Bool {
        await EpisodeTransition(host: self).perform(saveAfter: true) {
            self.outlineCommands(prepared: true).moveEpisode(episodeID, from: sourceChapterID, to: destinationChapterID, before: targetEpisodeID)
        }
    }

    func selectPlotOutlineAfterTransition(_ selection: PlotOutlineSelection) async {
        guard permitsDocumentInteraction else { return }
        selectPlotOutline(selection)
        _ = await saveNow()
    }

    func movePlotCardFromOutlineAfterTransition(
        id: PlotCardID,
        to selection: PlotOutlineSelection
    ) async -> Bool {
        guard permitsDocumentInteraction,
              movePlotCardFromOutline(id: id, to: selection) else { return false }
        return await saveNow()
    }

    /// Creating a work is available from the library without opening an editor.
    /// Editing/exporting the current document still requires a ready workbench.
    var permitsNewDocument: Bool {
        guard snapshotSyncV2Application != nil,
              !workspaceModel.isDocumentTransitionInProgress, !isTerminationPending,
              interactiveAuthOperationCount == 0 else { return false }
        switch startupState {
        case .ready, .documentSelection: return true
        case .loading, .recovery: return false
        }
    }

    func createNewDocument(expectedSession: WorkspaceSessionToken? = nil) async -> Bool {
        guard permitsNewDocument,
              expectedSession == nil || expectedSession == workspaceModel.documentSessionToken else { return false }
        return await createNewV2Document()
    }

    /// Import is available from the empty shelf as well as an open document.
    /// Keep the same runtime, transition, termination and authentication gates as creation.
    var permitsDocumentImport: Bool {
        permitsNewDocument
    }

    func openDocument(at url: URL, expectedSession: WorkspaceSessionToken? = nil) async -> Bool {
        guard permitsDocumentImport,
              expectedSession == nil || expectedSession == workspaceModel.documentSessionToken else { return false }
        return await openExternalDocument(at: url)
    }

    func importExternalDocument(at url: URL, expectedSession: WorkspaceSessionToken? = nil) async -> Bool {
        await openDocument(at: url, expectedSession: expectedSession)
    }

    func exportDocumentPackage(
        to destination: URL,
        expectedSession: WorkspaceSessionToken? = nil,
        readable: Bool = false
    ) async throws {
        let result: Result<Void, Error> = await documentOperationGate.perform { [weak self] in
            guard let self,
                  permitsDocumentTransitionOperation,
                  expectedSession == nil || expectedSession == workspaceModel.documentSessionToken,
                  editorCommandSession.prepareForDocumentTransition() else {
                return .failure(CancellationError())
            }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            workspaceModel.isDocumentTransitionInProgress = true
            defer { workspaceModel.isDocumentTransitionInProgress = false }
            let gateSession = workspaceModel.documentSessionToken
            let gateWorkID = currentSnapshotSyncV2WorkID
            guard await saveNow() else { return .failure(CancellationError()) }
            guard workspaceModel.documentSessionToken == gateSession,
                  currentSnapshotSyncV2WorkID == gateWorkID,
                  expectedSession == nil || expectedSession == workspaceModel.documentSessionToken else {
                return .failure(CancellationError())
            }
            do {
                if readable {
                    try await ReadableExport.write(workspaceModel.document, attachments: snapshotSyncV2Attachments,
                                                   resources: snapshotSyncV2Resources, to: destination)
                } else {
                    try await portableBridge.exportExplicitPackage(
                        document: workspaceModel.document,
                        attachments: snapshotSyncV2Attachments,
                        documentCreatedAt: snapshotSyncV2PortableCreatedAt
                            ?? snapshotSyncV2DocumentCreatedAt.map(Self.normalizedSnapshotSyncV2Date),
                        resources: snapshotSyncV2Resources,
                        to: destination
                    )
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }
}
