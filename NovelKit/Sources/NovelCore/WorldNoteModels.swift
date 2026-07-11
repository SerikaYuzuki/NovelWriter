import Foundation

/// 世界観ノートを一意に識別するID。
///
/// `EpisodeID` と取り違えないよう、UUIDを専用の値型で包む。
public struct WorldNoteID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }
}

extension WorldNoteID: CustomStringConvertible {
    public var description: String {
        rawValue.uuidString
    }
}

/// 作品の世界観を記録する章立てのないノート。
///
/// ノートの並び順は `NovelDocument.worldNotes` の配列順が唯一の正であり、
/// `order` フィールドは持たない。
public struct WorldNote: Codable, Sendable, Identifiable, Equatable {
    public var id: WorldNoteID
    public var title: String
    public var content: String

    public init(id: WorldNoteID = WorldNoteID(), title: String, content: String = "") {
        self.id = id
        self.title = title
        self.content = content
    }
}
