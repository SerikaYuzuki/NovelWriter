import Foundation
import NovelCore
import NovelThumbnail
import NovelWritingSupport

@MainActor
public struct WritingAssistantHost {
    public typealias Transmission = @MainActor (String, AssistantPurpose, UserDefaults, Double,
                                                @escaping @MainActor (AssistantProgress) -> Void) async throws -> String

    public let contextID: String
    public var workID: UUID = .init()
    public var accountID: String = ""
    public var localAccountID: String?
    public var defaults: UserDefaults = .init()
    public var requestCenter: AssistantRequestCenter = .init()
    public var withBackgroundTime: @MainActor (@escaping @MainActor () async throws -> String) async throws -> String = { try await $0() }
    public var transmit: Transmission = { _, _, _, _, _ in throw WritingError.unavailable }
    public let capture: () throws -> WritingCapture
    public let records: (_ common: Bool) async throws -> [WritingEnvelope]
    public let append: (WritingRecord) async throws -> Void
    public let synchronize: () async throws -> Void
    public let apply: (WritingEdit, WritingGrant) async throws -> Void
    public var applyExactProofreading: (WritingEdit, WritingGrant, EpisodeID, String) async throws -> Void = { _, _, _, _ in throw WritingError.unavailable }
    public let undo: (UUID) async throws -> Void
    public var syncScheduler: WritingSyncScheduler?
    public var editState: (UUID) async throws -> String? = { _ in nil }
    public var localEdit: (UUID) async throws -> WritingEdit? = { _ in nil }
    public var editOutcome: (WritingEdit) async throws -> String? = { _ in nil }

    #if os(macOS)
    public var readThumbnail: (ThumbnailOwner) async throws -> Data? = { _ in throw WritingError.unavailable }
    public var applyThumbnail: (WritingThumbnailEditRequest, WritingGrant) async throws -> String = { _, _ in throw WritingError.unavailable }
    #endif

    public init(contextID: String, workID: UUID = UUID(), accountID: String = "",
                defaults: UserDefaults = UserDefaults(), requestCenter: AssistantRequestCenter = AssistantRequestCenter(),
                capture: @escaping () throws -> WritingCapture,
                records: @escaping (Bool) async throws -> [WritingEnvelope],
                append: @escaping (WritingRecord) async throws -> Void,
                synchronize: @escaping () async throws -> Void,
                apply: @escaping (WritingEdit, WritingGrant) async throws -> Void,
                undo: @escaping (UUID) async throws -> Void,
                syncScheduler: WritingSyncScheduler? = nil,
                editState: @escaping (UUID) async throws -> String? = { _ in nil },
                editOutcome: @escaping (WritingEdit) async throws -> String? = { _ in nil }) {
        self.contextID = contextID; self.workID = workID; self.accountID = accountID
        self.defaults = defaults; self.requestCenter = requestCenter; self.capture = capture
        self.records = records; self.append = append; self.synchronize = synchronize
        self.apply = apply; self.undo = undo; self.syncScheduler = syncScheduler
        self.editState = editState; self.editOutcome = editOutcome
    }

    #if os(macOS)
    public init(contextID: String, workID: UUID = UUID(), accountID: String = "",
                defaults: UserDefaults = UserDefaults(), requestCenter: AssistantRequestCenter = AssistantRequestCenter(),
                capture: @escaping () throws -> WritingCapture,
                records: @escaping (Bool) async throws -> [WritingEnvelope],
                append: @escaping (WritingRecord) async throws -> Void,
                synchronize: @escaping () async throws -> Void,
                apply: @escaping (WritingEdit, WritingGrant) async throws -> Void,
                undo: @escaping (UUID) async throws -> Void,
                syncScheduler: WritingSyncScheduler? = nil,
                editState: @escaping (UUID) async throws -> String? = { _ in nil },
                editOutcome: @escaping (WritingEdit) async throws -> String? = { _ in nil },
                readThumbnail: @escaping (ThumbnailOwner) async throws -> Data?,
                applyThumbnail: @escaping (WritingThumbnailEditRequest, WritingGrant) async throws -> String) {
        self.contextID = contextID; self.workID = workID; self.accountID = accountID
        self.defaults = defaults; self.requestCenter = requestCenter; self.capture = capture
        self.records = records; self.append = append; self.synchronize = synchronize
        self.apply = apply; self.undo = undo; self.syncScheduler = syncScheduler
        self.editState = editState; self.editOutcome = editOutcome
        self.readThumbnail = readThumbnail; self.applyThumbnail = applyThumbnail
    }

    #endif

    public func synchronizeNow() async throws {
        if let syncScheduler {
            try await syncScheduler.synchronize(contextID: contextID)
        } else {
            try await synchronize()
        }
    }

    public func captureWhenReady() async throws -> WritingCapture {
        try await WritingCompositionBoundary.capture(capture)
    }
}
