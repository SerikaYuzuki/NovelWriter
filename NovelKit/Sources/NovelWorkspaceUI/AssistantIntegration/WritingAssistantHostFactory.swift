import Foundation
import NovelCore
import NovelSyncV2Application
import NovelWorkspace
import NovelWritingSupport

@MainActor
public enum WritingAssistantHostFactory {
    public typealias ThumbnailUndo = @MainActor (UUID, SyncV2Application, SyncV2WritingContext, @MainActor () throws -> Void) async throws -> Void

    public static func make(host: any WorkspaceWritingHost, contextID: String, thumbnailUndo: ThumbnailUndo? = nil) -> WritingAssistantHost? {
        let scope = host.operationContext
        guard let application = host.writingApplication, let work = scope.workID,
              let workUUID = UUID(uuidString: work.description) else { return nil }
        let validate: @MainActor () throws -> Void = { [weak host] in
            guard !Task.isCancelled, let host, host.writingInteractionAllowed,
                  matches(scope, host.operationContext) else { throw WritingError.changedScope }
        }
        // Record delivery belongs to the captured work even after navigating to another work.
        let context: () async throws -> SyncV2WritingContext = { [weak host] in
            guard let host, host.operationContext.account == scope.account else { throw WritingError.changedScope }
            let result = try await application.writingContext(workID: work)
            guard host.operationContext.account == scope.account else { throw WritingError.changedScope }
            return result
        }
        let scheduler = host.writingSyncScheduler
        var result = WritingAssistantHost(contextID: contextID, workID: workUUID, accountID: String(describing: scope.account),
                                          defaults: host.userDefaults, requestCenter: host.workspaceModel.assistantRequestCenter,
                                          capture: { [weak host] in
                                              try validate(); guard let host else { throw WritingError.changedScope }
                                              return try capture(host: host, workUUID: workUUID)
                                          }, records: { common in
                                              try await application.writingRecords(context: context(), common: common)
                                          }, append: { record in
                                              try await application.appendWritingRecord(record, context: context())
                                              scheduler.recordAppended(contextID: contextID)
                                          }, synchronize: {
                                              try await application.synchronizeWriting(context: context())
                                          }, apply: { [weak host] edit, grant in
                                              try validate(); guard let host else { throw WritingError.changedScope }
                                              defer { scheduler.recordAppended(contextID: contextID) }
                                              try await applyWritingEdit(edit, grant: grant, host: host, application: application,
                                                                         context: context(), validate: validate)
                                          }, undo: { [weak host] id in
                                              try validate(); guard let host else { throw WritingError.changedScope }
                                              defer { scheduler.recordAppended(contextID: contextID) }
                                              let ctx = try await context()
                                              guard let journal = try await application.writingEdit(id: id, context: ctx),
                                                    ["applied", "prepared"].contains(journal.state) else { throw WritingError.interrupted }
                                              let edit = try JSONDecoder().decode(WritingStoredEdit.self, from: Data(journal.payload.utf8)).prepared
                                              if edit.changes.first?.path.first == "thumbnails", let thumbnailUndo {
                                                  try await thumbnailUndo(id, application, ctx, validate)
                                                  return
                                              }
                                              try await applyWritingEdit(edit.inverse, grant: .wholeWork, host: host, application: application,
                                                                         context: ctx, validate: validate)
                                              try await application.finishWritingEdit(id: id, state: "undone", context: ctx)
                                          }, syncScheduler: scheduler, editState: { id in
                                              try await application.writingEdit(id: id, context: context())?.state
                                          }, editOutcome: { edit in
                                              try await application.writingEditOutcome(edit, context: context())
                                          })
        result.localAccountID = scope.account.accountID ?? "local"
        result.localEdit = { id in
            guard let journal = try await application.writingEdit(id: id, context: context()) else { return nil }
            return try JSONDecoder().decode(WritingStoredEdit.self, from: Data(journal.payload.utf8)).prepared
        }
        result.applyExactProofreading = { [weak host] edit, grant, episode, text in
            try validate(); guard let host else { throw WritingError.changedScope }
            defer { scheduler.recordAppended(contextID: contextID) }
            try await applyWritingEdit(edit, grant: grant, host: host, application: application,
                                       context: context(), validate: validate, exactEpisode: (episode, text))
        }
        return result
    }

    public static func capture(host: any WorkspaceWritingHost, workUUID: UUID) throws -> WritingCapture {
        guard host.writingInteractionAllowed else { throw WritingError.changedScope }
        var document = host.document
        switch host.captureCommittedText() {
        case .compositionInProgress: throw AssistantError.composing
        case let .captured(text):
            if let chapter = host.selectedChapterID, let episode = host.selectedEpisodeID {
                document.updateEpisodeContent(text, for: episode, in: chapter)
            }
        case .notActive: break
        }
        return try WritingCapture(workId: workUUID, document: document, episodeId: host.selectedEpisodeID,
                                  attachments: host.writingAttachments())
    }

    private static func matches(_ expected: WorkspaceOperationContext, _ current: WorkspaceOperationContext) -> Bool {
        expected.workID == current.workID && expected.session == current.session && expected.account == current.account
    }

    static func applyWritingEdit(_ edit: WritingEdit, grant: WritingGrant, host: any WorkspaceWritingHost, application: SyncV2Application,
                                 context: SyncV2WritingContext, validate: () throws -> Void, exactEpisode: (EpisodeID, String)? = nil) async throws {
        _ = try await WritingCompositionBoundary.capture {
            try validate(); return try capture(host: host, workUUID: edit.workId)
        }
        let requested = edit
        let result: Result<Void, Error> = await host.documentOperationGate.perform {
            do {
                try validate()
                let initial = try await WritingCompositionBoundary.capture {
                    try validate(); return try capture(host: host, workUUID: edit.workId)
                }
                if let (episode, text) = exactEpisode {
                    guard initial.episodeId == episode, initial.document.chapters.flatMap(\.episodes).first(where: { $0.id == episode })?.content == text else { throw WritingError.changedTarget }
                }
                let edit = try edit.prepared(for: initial.document, attachments: initial.attachments)
                _ = try edit.applying(to: initial.document, attachments: initial.attachments, grant: grant)
                guard try await application.claimWritingEdit(requested, prepared: edit, context: context) else { throw WritingError.alreadyApplied }
                do {
                    try validate()
                    let current = try await WritingCompositionBoundary.capture {
                        try validate(); return try capture(host: host, workUUID: edit.workId)
                    }
                    if let (episode, text) = exactEpisode {
                        guard current.episodeId == episode, current.document.chapters.flatMap(\.episodes).first(where: { $0.id == episode })?.content == text else { throw WritingError.changedTarget }
                    }
                    let mutation = try edit.applying(to: current.document, attachments: current.attachments, grant: grant)
                    let replacement = mutation.document
                    let mergedAttachments = try WritingThumbnailBoundary.merging(mutation.attachments,
                                                                                 with: host.writingAttachments(),
                                                                                 from: current.document, to: replacement)
                    if let id = host.selectedEpisodeID,
                       let old = current.document.episode(id)?.episode,
                       let new = replacement.episode(id)?.episode, old.content != new.content {
                        if case .captured = host.captureCommittedText() {
                            guard host.applyUncountedProofreading(expectedText: old.content, replacement: new.content) else {
                                throw WritingError.changedTarget
                            }
                        } else {
                            host.invalidateEditorContent()
                        }
                    }
                    try host.installWritingMutation(replacement, attachments: mergedAttachments)
                    host.markWritingDocumentChanged()
                } catch {
                    try? await application.finishWritingEdit(id: edit.id, state: "rejected", context: context)
                    throw error
                }
                // Journal remains prepared on a failed checkpoint; it is never auto-replayed.
                guard await host.saveWritingChanges() else { throw WritingError.interrupted }
                try await application.finishWritingEdit(id: edit.id, state: "applied", context: context)
                return .success(())
            } catch { return .failure(error) }
        }
        try result.get()
    }
}
