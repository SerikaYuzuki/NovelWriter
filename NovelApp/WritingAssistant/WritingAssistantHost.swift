import Foundation
import NovelCore
import NovelThumbnail
import NovelWorkspaceUI
import NovelWritingSupport

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

    #if os(macOS)
    var readThumbnail: (ThumbnailOwner) async throws -> Data? = { _ in throw WritingError.unavailable }
    var applyThumbnail: (WritingMCPThumbnailRequest, WritingGrant) async throws -> String = { _, _ in throw WritingError.unavailable }
    #endif

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
