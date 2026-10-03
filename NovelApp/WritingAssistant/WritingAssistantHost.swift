import Foundation
import NovelCore
import NovelThumbnail
import NovelWritingSupport

struct WritingCapture {
    let workId: UUID
    let document: NovelDocument
    let episodeId: EpisodeID?
    var attachments: [WritingAttachment]
    init(workId: UUID, document: NovelDocument, episodeId: EpisodeID?, attachments: [WritingAttachment] = []) {
        self.workId = workId; self.document = document; self.episodeId = episodeId
        self.attachments = attachments.filter { !ThumbnailOwner.isReserved($0.fileName) }
    }

    var episodePath: [String]? {
        guard let episodeId, let chapter = document.chapters.first(where: { $0.episodes.contains { $0.id == episodeId } }) else { return nil }
        return ["chapters", chapter.id.rawValue.uuidString.lowercased(), "episodes", episodeId.rawValue.uuidString.lowercased()]
    }
}

@MainActor
struct WritingAssistantHost {
    let contextID: String
    let capture: () throws -> WritingCapture
    let records: (_ common: Bool) async throws -> [WritingEnvelope]
    let append: (WritingRecord) async throws -> Void
    let synchronize: () async throws -> Void
    let apply: (WritingEdit, WritingGrant) async throws -> Void
    let undo: (UUID) async throws -> Void
    var syncScheduler: WritingSyncScheduler?
    var editState: (UUID) async throws -> String? = { _ in nil }
    var editOutcome: (WritingEdit) async throws -> String? = { _ in nil }

    func synchronizeNow() async throws {
        if let syncScheduler {
            try await syncScheduler.synchronize(contextID: contextID)
        } else {
            try await synchronize()
        }
    }

    func captureWhenReady() async throws -> WritingCapture {
        try await WritingCompositionBoundary.capture(capture)
    }
}

@MainActor
enum WritingCompositionBoundary {
    /// Wait without committing marked text or blocking typing. Captures validate
    /// the work/session/account each time; cancellation never leaves a grant active.
    static func capture<T>(timeout: Duration = .seconds(15), _ read: () throws -> T) async throws -> T {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            do { return try read() }
            catch AssistantError.composing {
                guard clock.now < deadline else { throw AssistantError.composing }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
