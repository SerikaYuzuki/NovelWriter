import Foundation
import NovelCore
import NovelThumbnail
import NovelWritingSupport

public struct WritingCapture {
    public let workId: UUID
    public let document: NovelDocument
    public let episodeId: EpisodeID?
    public var attachments: [WritingAttachment]
    public init(workId: UUID, document: NovelDocument, episodeId: EpisodeID?, attachments: [WritingAttachment] = []) {
        self.workId = workId; self.document = document; self.episodeId = episodeId
        self.attachments = attachments.filter { !ThumbnailOwner.isReserved($0.fileName) }
    }

    public var episodePath: [String]? {
        guard let episodeId, let chapter = document.chapters.first(where: { $0.episodes.contains { $0.id == episodeId } }) else { return nil }
        return ["chapters", chapter.id.rawValue.uuidString.lowercased(), "episodes", episodeId.rawValue.uuidString.lowercased()]
    }
}

@MainActor
public enum WritingCompositionBoundary {
    /// Wait without committing marked text or blocking typing. Captures validate
    /// the work/session/account each time; cancellation never leaves a grant active.
    public static func capture<T>(timeout: Duration = .seconds(15), _ read: () throws -> T) async throws -> T {
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
