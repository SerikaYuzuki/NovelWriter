import Foundation
import NovelCore

/// JSON values, with array members addressed by stable model IDs rather than indices.
public enum WritingValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([WritingValue]), object([String: WritingValue])
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let payload = try? container.decode(Bool.self) {
            self = .bool(payload)
        } else if let payload = try? container.decode(String.self) {
            self = .string(payload)
        } else if let payload = try? container.decode(Double.self) {
            self = .number(payload)
        } else if let payload = try? container.decode([WritingValue].self) {
            self = .array(payload)
        } else {
            self = try .object(container.decode([String: WritingValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(payload): try container.encode(payload)
        case let .number(payload): try container.encode(payload)
        case let .string(payload): try container.encode(payload)
        case let .array(payload): try container.encode(payload)
        case let .object(payload): try container.encode(payload)
        }
    }

    public static func document(_ document: NovelDocument) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(document))
    }

    public var text: String? {
        if case let .string(payload) = self {
            payload
        } else {
            nil
        }
    }

    var stableID: String? {
        guard case let .object(payload) = self else { return nil }
        if case let .object(id)? = payload["id"], let value = id["rawValue"]?.text {
            return value.lowercased()
        }
        return payload["id"]?.text?.lowercased()
    }

    public func at(_ path: [String]) throws -> Self? {
        guard let first = path.first else { return self }
        switch self {
        case let .object(payload): return try payload[first]?.at(Array(path.dropFirst()))
        case let .array(payload): return try payload.first { $0.stableID == first.lowercased() }?.at(Array(path.dropFirst()))
        default: throw WritingError.invalidEdit
        }
    }

    mutating func set(_ path: [String], to value: Self?, position: Int? = nil) throws {
        guard let first = path.first else {
            guard let value else { throw WritingError.invalidEdit }; self = value; return
        }
        let tail = Array(path.dropFirst())
        switch self {
        case var .object(payload):
            if tail.isEmpty {
                payload[first] = value
            } else {
                guard payload[first] != nil else { throw WritingError.invalidEdit }
                try payload[first]!.set(tail, to: value, position: position)
            }
            self = .object(payload)
        case var .array(payload):
            if let index = payload.firstIndex(where: { $0.stableID == first.lowercased() }) {
                if tail.isEmpty, value == nil {
                    payload.remove(at: index)
                } else {
                    try payload[index].set(tail, to: value, position: position)
                }
            } else {
                guard tail.isEmpty, let value, value.stableID == first.lowercased() else { throw WritingError.invalidEdit }
                payload.insert(value, at: min(max(position ?? payload.count, 0), payload.count))
            }
            self = .array(payload)
        default: throw WritingError.invalidEdit
        }
    }
}

public struct WritingChange: Codable, Equatable, Sendable {
    public var path: [String]
    public var position: Int?
    public var before: WritingValue?
    public var after: WritingValue?
    public init(path: [String], before: WritingValue?, after: WritingValue?, position: Int? = nil) {
        self.path = path; self.before = before; self.after = after; self.position = position
    }
}

public struct WritingGrant: Codable, Equatable, Sendable {
    public var paths: [[String]]
    public var appendOnly: Bool
    public init(paths: [[String]], appendOnly: Bool = false) {
        self.paths = paths; self.appendOnly = appendOnly
    }

    public static let readOnly = Self(paths: [])
    public static let wholeWork = Self(paths: [
        ["title"],
        ["synopsis"],
        ["chapters"],
        ["characters"],
        ["plotCards"],
        ["flags"],
        ["worldNotes"],
        ["attachments"]
    ])
    public func permits(_ path: [String]) -> Bool {
        !path.isEmpty && paths.contains { !$0.isEmpty && path.starts(with: $0) }
    }
}

public struct WritingEdit: Codable, Sendable, Equatable {
    public var id: UUID
    public var workId: UUID
    public var documentId: UUID
    public var changes: [WritingChange]
    public init(id: UUID = UUID(), workId: UUID, documentId: UUID, changes: [WritingChange]) {
        self.id = id; self.workId = workId; self.documentId = documentId; self.changes = changes
    }

    public var inverse: Self {
        Self(workId: workId, documentId: documentId, changes: changes.reversed().map {
            WritingChange(path: $0.path, before: $0.after, after: $0.before, position: $0.position)
        })
    }

    public func prepared(for document: NovelDocument) throws -> Self {
        let value = try WritingValue.document(document)
        var result = self
        for index in result.changes.indices where result.changes[index].after == nil {
            let path = result.changes[index].path
            if let last = path.last, case let .array(array)? = try value.at(Array(path.dropLast())) {
                result.changes[index].position = array.firstIndex { $0.stableID == last.lowercased() }
            }
        }
        return result
    }

    public func applying(to document: NovelDocument, grant: WritingGrant) throws -> NovelDocument {
        guard document.id == documentId, changes.count <= 100 else { throw WritingError.changedScope }
        var value = try WritingValue.document(document)
        for (index, change) in changes.enumerated() {
            let path = change.path
            guard WritingGrant.wholeWork.permits(path), grant.permits(path),
                  !path.contains("id"), !path.contains("rawValue"),
                  change.before != change.after else { throw WritingError.outsideGrant }
            // Overlapping changes are ambiguous and can hide grant or stale-base errors.
            guard !changes.prefix(index).contains(where: { $0.path.starts(with: path) || path.starts(with: $0.path) }) else {
                throw WritingError.invalidEdit
            }
            if let identity = change.before?.stableID {
                guard change.after == nil || change.after?.stableID == identity else { throw WritingError.invalidEdit }
            }
            let current = try value.at(path)
            if grant.appendOnly {
                guard path.last == "content", let before = change.before?.text,
                      let after = change.after?.text, after.hasPrefix(before) else { throw WritingError.outsideGrant }
            }
            var applied = change.after
            if case let .array(old)? = change.before {
                guard case let .array(new)? = change.after, case let .array(now)? = current,
                      old.count == new.count, old.allSatisfy({ new.contains($0) }),
                      Set(old.compactMap(\.stableID)) == Set(new.compactMap(\.stableID)),
                      now.compactMap(\.stableID) == old.compactMap(\.stableID) else { throw WritingError.changedTarget }
                let lookup = Dictionary(uniqueKeysWithValues: now.compactMap { item in item.stableID.map { ($0, item) } })
                applied = .array(new.compactMap { $0.stableID.flatMap { lookup[$0] } })
            } else if let before = change.before?.text, let after = change.after?.text, let now = current?.text,
                      path.last == "content" {
                applied = try .string(WritingTextMerge.apply(before: before, after: after, current: now))
            } else {
                guard current == change.before else { throw WritingError.changedTarget }
            }
            try value.set(path, to: applied, position: change.position)
        }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16 * 1024 * 1024,
              let result = try? JSONDecoder().decode(NovelDocument.self, from: data),
              result.id == documentId, try WritingValue.document(result) == value else { throw WritingError.invalidEdit }
        try Self.validateIDs(value)
        let episodeIDs = result.chapters.flatMap(\.episodes).map(\.id)
        guard Set(episodeIDs).count == episodeIDs.count else { throw WritingError.invalidEdit }
        let chapterIDs = Set(result.chapters.map(\.id))
        guard result.plotCards.allSatisfy({ $0.chapterID.map(chapterIDs.contains) ?? true }),
              result.flags
              .allSatisfy({ ($0.plantedChapterID.map(chapterIDs.contains) ?? true) && ($0.resolvedChapterID.map(chapterIDs.contains) ?? true) }) else { throw WritingError.invalidEdit }
        return result
    }

    private static func validateIDs(_ value: WritingValue) throws {
        switch value {
        case let .array(values):
            let ids = values.compactMap(\.stableID)
            guard Set(ids).count == ids.count else { throw WritingError.invalidEdit }
            for payload in values {
                try validateIDs(payload)
            }
        case let .object(values): for payload in values.values {
                try validateIDs(payload)
            }
        default: break
        }
    }
}

/// Request identity and the extra local information needed to reverse it.
public struct WritingStoredEdit: Codable, Sendable {
    public let requested: WritingEdit
    public let prepared: WritingEdit
    public init(requested: WritingEdit, prepared: WritingEdit) {
        self.requested = requested; self.prepared = prepared
    }
}
