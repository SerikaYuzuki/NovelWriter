import Foundation

/// Separate from the manuscript snapshot. No credentials or executable grants.
public struct WritingRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var workId: UUID?
    public var kind: String
    public var key: String
    public var parentId: UUID?
    public var createdAt: String
    public var payload: String

    public init(id: UUID = UUID(), workId: UUID?, kind: String, key: String,
                parentId: UUID? = nil, payload: String) {
        self.id = id; self.workId = workId; self.kind = kind; self.key = key
        self.parentId = parentId; self.payload = payload
        createdAt = Date().ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(payload.utf8))
    }

    public static func payload(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }
}

public struct WritingEnvelope: Codable, Equatable, Sendable, Identifiable {
    public var record: WritingRecord
    public var sequence: Int64
    public var conflicted: Bool
    public var id: UUID {
        record.id
    }

    public init(record: WritingRecord, sequence: Int64 = 0, conflicted: Bool = false) {
        self.record = record; self.sequence = sequence; self.conflicted = conflicted
    }
}

public struct WritingRecordPage: Codable, Sendable {
    public var items: [WritingEnvelope]
    public var nextAfter: Int64?
    public init(items: [WritingEnvelope], nextAfter: Int64? = nil) {
        self.items = items; self.nextAfter = nextAfter
    }
}

public struct WritingPrompt: Codable, Sendable { public var text: String; public init(text: String) {
    self.text = text
} }
public struct WritingMessage: Codable, Sendable {
    public var role: String
    public var text: String
    public var requestId: UUID?
    public init(role: String, text: String, requestId: UUID? = nil) {
        self.role = role; self.text = text; self.requestId = requestId
    }
}

public enum WritingError: String, Error, LocalizedError {
    case unavailable, invalidRecord, changedScope, outsideGrant, changedTarget, invalidEdit, alreadyApplied, interrupted
    public var errorDescription: String? {
        switch self {
        case .unavailable: "AI用の保存領域を開けませんでした。原稿の保存は利用できます。"
        case .invalidRecord: "AIの記録を読み取れませんでした。"
        case .changedScope: "作品またはアカウントが変わったため、操作を止めました。"
        case .outsideGrant: "許可した範囲を超える変更は反映しませんでした。"
        case .changedTarget: "対象が編集されたため反映しませんでした。回答は会話に残っています。"
        case .invalidEdit: "変更の形式が正しくないため反映しませんでした。"
        case .alreadyApplied: "この操作は処理済みです。重複して反映しません。"
        case .interrupted: "処理が中断しました。自動で送り直すことはありません。"
        }
    }
}

public protocol WritingLocalPersistence: Sendable {
    func copyHistory(source: String, destination: String, newWorkID: UUID) async throws
    func retryHistoryCopies() async throws
    func records(namespace: String) async throws -> [WritingEnvelope]
    func append(_ record: WritingRecord, namespace: String) async throws
    func pending(namespace: String) async throws -> [WritingRecord]
    func accept(_ envelope: WritingEnvelope, namespace: String) async throws
    func cursor(namespace: String, remote: String) async throws -> Int64
    func advance(_ sequence: Int64, namespace: String, remote: String) async throws
    /// Durable claim before applying. Claims never expire or replay after a crash.
    func claimEdit(id: UUID, namespace: String, payload: String) async throws -> Bool
    func finishEdit(id: UUID, namespace: String, state: String) async throws
    func edit(id: UUID, namespace: String) async throws -> WritingEditJournal?
}

public struct WritingEditJournal: Codable, Sendable {
    public let payload: String
    public let state: String
    public init(payload: String, state: String) {
        self.payload = payload; self.state = state
    }
}
