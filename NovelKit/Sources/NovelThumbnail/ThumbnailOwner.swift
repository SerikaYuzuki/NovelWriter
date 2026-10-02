import Foundation
import NovelCore

/// D-104: binding is the reserved name, never the attachment identity.
public struct ThumbnailOwner: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case work, character
        case worldNote = "world-note"
    }

    public let kind: Kind
    public let id: UUID
    public init(_ kind: Kind, _ id: UUID) {
        self.kind = kind; self.id = id
    }

    public var fileName: String {
        "fuminiwa-thumbnail-v1-\(kind.rawValue)-\(id.uuidString.lowercased()).jpg"
    }

    public var aspectRatio: Double {
        kind == .work ? 2.0 / 3.0 : 1
    }

    public var maximumEdge: Int {
        kind == .work ? 1024 : 768
    }

    public init?(fileName: String) {
        for kind in Kind.allCases {
            let prefix = "fuminiwa-thumbnail-v1-\(kind.rawValue)-"
            guard fileName.hasPrefix(prefix), fileName.hasSuffix(".jpg") else { continue }
            let value = String(fileName.dropFirst(prefix.count).dropLast(4))
            guard let id = UUID(uuidString: value), value == id.uuidString.lowercased() else { return nil }
            self.init(kind, id); return
        }
        return nil
    }

    /// Protect even unknown versions/malformed reserved names from AI access.
    public static func isReserved(_ name: String) -> Bool {
        name.lowercased().hasPrefix("fuminiwa-thumbnail-")
    }

    public func exists(in document: NovelDocument) -> Bool {
        switch kind {
        case .work: document.id == id
        case .character: document.characters.contains { $0.id.rawValue == id }
        case .worldNote: document.worldNotes.contains { $0.id.rawValue == id }
        }
    }

    /// Only owners removed by this edit qualify; pre-existing orphans are retained.
    public static func removedNames(from old: NovelDocument, to new: NovelDocument) -> Set<String> {
        let owners = old.characters.map { Self(.character, $0.id.rawValue) }
            + old.worldNotes.map { Self(.worldNote, $0.id.rawValue) }
        return Set(owners.filter { !$0.exists(in: new) }.map(\.fileName))
    }
}
