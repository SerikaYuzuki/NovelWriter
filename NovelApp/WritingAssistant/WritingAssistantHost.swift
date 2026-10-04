import Foundation
import NovelCore
import NovelThumbnail
import NovelWorkspaceUI
import NovelWritingSupport

@MainActor
struct WritingAssistantHost {
    let contextID: String
    var workID: UUID = .init()
    var accountID: String = ""
    var localAccountID: String?
    var defaults: UserDefaults = .init()
    var requestCenter: AssistantRequestCenter = .init()
    var withBackgroundTime: @MainActor (@escaping @MainActor () async throws -> String) async throws -> String = { try await $0() }
    var transmit: @MainActor (String, AssistantPurpose, UserDefaults, Double, @escaping @MainActor (AssistantProgress) -> Void) async throws -> String = AssistantTransport.sendSaved
    let capture: () throws -> WritingCapture
    let records: (_ common: Bool) async throws -> [WritingEnvelope]
    let append: (WritingRecord) async throws -> Void
    let synchronize: () async throws -> Void
    let apply: (WritingEdit, WritingGrant) async throws -> Void
    var applyExactProofreading: (WritingEdit, WritingGrant, EpisodeID, String) async throws -> Void = { _, _, _, _ in throw WritingError.unavailable }
    let undo: (UUID) async throws -> Void
    var syncScheduler: WritingSyncScheduler?
    var editState: (UUID) async throws -> String? = { _ in nil }
    var localEdit: (UUID) async throws -> WritingEdit? = { _ in nil }
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
