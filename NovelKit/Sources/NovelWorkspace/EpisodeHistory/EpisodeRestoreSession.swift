import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelTextAnalysis
import NovelWritingSupport
import Observation

public struct EpisodeRestoreRequest: Identifiable {
    public let id = UUID()
    public let scope: String
    public let change: EpisodeTextChange

    public init(scope: String, chapterID: ChapterID, episodeID: EpisodeID, before: String, after: String) {
        self.init(scope: scope, change: EpisodeTextChange(chapterID: chapterID, episodeID: episodeID,
                                                          before: before, after: after, count: 1))
    }

    public init(scope: String, change: EpisodeTextChange) {
        self.scope = scope
        self.change = change
    }
}

/// Uses the common WritingEdit validator and durable Undo journal. No network
/// synchronization participates in manuscript saving.
@MainActor
public final class EpisodeRestoreJournal {
    private let prepare: (EpisodeTextChange, NovelDocument) async throws -> UUID
    private let finish: (UUID, String) async throws -> Void

    public init(prepare: @escaping (EpisodeTextChange, NovelDocument) async throws -> UUID,
                finish: @escaping (UUID, String) async throws -> Void) {
        self.prepare = prepare
        self.finish = finish
    }

    public convenience init(application: SyncV2Application, workID: WorkID) {
        var contexts: [UUID: SyncV2WritingContext] = [:]
        self.init(prepare: { change, document in
            guard let work = UUID(uuidString: workID.description) else { throw WritingError.changedScope }
            let path = ["chapters", change.chapterID.rawValue.uuidString.lowercased(), "episodes", change.episodeID.rawValue.uuidString.lowercased(), "content"]
            let edit = WritingEdit(workId: work, documentId: document.id, changes: [
                WritingChange(path: path, before: .string(change.before), after: .string(change.after))
            ])
            let prepared = try edit.prepared(for: document)
            _ = try prepared.applying(to: document, grant: WritingGrant(paths: [path]))
            let context = try await application.writingContext(workID: workID)
            guard try await application.claimWritingEdit(edit, prepared: prepared, context: context) else {
                throw WritingError.alreadyApplied
            }
            contexts[edit.id] = context
            return edit.id
        }, finish: { id, state in
            guard let context = contexts[id] else { throw WritingError.changedScope }
            try await application.finishWritingEdit(id: id, state: state, context: context)
            contexts[id] = nil
        })
    }

    fileprivate func claim(_ change: EpisodeTextChange, document: NovelDocument) async throws -> UUID {
        try await prepare(change, document)
    }

    fileprivate func complete(_ id: UUID, state: String) async throws {
        try await finish(id, state)
    }
}

@MainActor
@Observable
public final class EpisodeRestoreSession {
    public static let confirmation = "現在の本文を履歴に残してから、この話だけを選んだ版へ戻します。他の話は変わりません。取り消し（Undo）で戻せます。"
    public private(set) var isRestoring = false
    public var message: String?

    public init() {}

    @discardableResult
    public func restore(_ request: EpisodeRestoreRequest, using host: WorkReplacementHost,
                        journal: EpisodeRestoreJournal) async -> Bool {
        guard !isRestoring, host.scope == request.scope, host.validate() else { return false }
        isRestoring = true
        message = nil
        defer { isRestoring = false }
        var applied = false
        var unchanged = false
        var editID: UUID?
        let saved = await host.boundary {
            guard host.validate(), request.change.matches(host.document()) else {
                self.message = "確認後に本文が変わりました。履歴を開き直してください。"
                return false
            }
            if request.change.before.utf8.elementsEqual(request.change.after.utf8) {
                unchanged = true
                return true
            }
            guard await host.snapshot() else {
                self.message = "復元前の履歴を保存できませんでした。本文は変更していません。"
                return false
            }
            guard host.validate(), request.change.matches(host.document()) else { return false }
            do {
                editID = try await journal.claim(request.change, document: host.document())
            } catch {
                self.message = "取り消し用の記録を保存できませんでした。本文は変更していません。"
                return false
            }
            guard host.validate(), request.change.matches(host.document()), host.apply([request.change]) else { return false }
            applied = true
            return true
        }
        if let editID {
            do {
                // Failed post-edit saves remain prepared, matching common editing.
                if !applied || saved {
                    try await journal.complete(editID, state: applied ? "applied" : "rejected")
                }
            } catch {
                if host.validate() {
                    message = "本文は復元しましたが、変更記録の確定に失敗しました。"
                }
                return false
            }
        }
        guard host.validate() else { return false }
        if unchanged {
            message = saved ? "現在と同じ本文です。" : "現在の本文を保存できませんでした。保存を再試行してください。"
        } else if applied {
            message = saved ? "この話を復元しました。" : "この話を復元しましたが保存できませんでした。保存を再試行してください。"
        } else if message == nil {
            message = "作品・本文・入力状態が変わったため復元していません。履歴を開き直してください。"
        }
        return saved && (applied || unchanged)
    }
}
