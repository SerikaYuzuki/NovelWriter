import Foundation
import NovelCore

public struct WritingAttachment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var fileName: String
    public var bytes: Data
    public init(id: UUID, fileName: String, bytes: Data) {
        self.id = id; self.fileName = fileName; self.bytes = bytes
    }

    public var value: WritingValue {
        get throws { try JSONDecoder().decode(WritingValue.self, from: JSONEncoder().encode(self)) }
    }
}

public struct WritingMutation: Sendable {
    public let document: NovelDocument
    public let attachments: [WritingAttachment]
}

public extension WritingEdit {
    func prepared(for document: NovelDocument, attachments: [WritingAttachment]) throws -> Self {
        var result = try prepared(for: document)
        for index in result.changes.indices where result.changes[index].path.first == "attachments" && result.changes[index].after == nil {
            result.changes[index].position = attachments.firstIndex { $0.id.uuidString.lowercased() == result.changes[index].path.last?.lowercased() }
        }
        return result
    }

    func applying(to document: NovelDocument, attachments: [WritingAttachment], grant: WritingGrant) throws -> WritingMutation {
        guard changes.count <= 100 else { throw WritingError.invalidEdit }
        var body = self; body.changes = changes.filter { $0.path.first != "attachments" }
        let newDocument = try body.applying(to: document, grant: grant)
        let fileChanges = changes.filter { $0.path.first == "attachments" }
        var result = attachments
        var touched: Set<[String]> = []
        for change in fileChanges {
            guard grant.permits(change.path), !grant.appendOnly,
                  !touched.contains(where: { $0.starts(with: change.path) || change.path.starts(with: $0) }) else { throw WritingError.outsideGrant }
            touched.insert(change.path)
            if change.path == ["attachments"] {
                let old = WritingValue.array(result.map { .string($0.id.uuidString.lowercased()) })
                guard change.before == old, case let .array(order)? = change.after,
                      order.count == result.count,
                      Set(order.compactMap(\.text)) == Set(result.map { $0.id.uuidString.lowercased() }) else { throw WritingError.changedTarget }
                let indexed = Dictionary(uniqueKeysWithValues: result.map { ($0.id.uuidString.lowercased(), $0) })
                result = order.compactMap { $0.text.flatMap { indexed[$0] } }
                continue
            }
            guard change.path.count == 2, let id = UUID(uuidString: change.path[1]) else { throw WritingError.invalidEdit }
            let index = result.firstIndex { $0.id == id }
            // Bound encoding to the selected file; unrelated large resources are never copied.
            if let index, result[index].bytes.count > 300_000 {
                throw WritingError.invalidEdit
            }
            let old = try index.map { try result[$0].value }
            guard old == change.before else { throw WritingError.changedTarget }
            if let after = change.after {
                let bytes = try JSONEncoder().encode(after)
                guard let file = try? JSONDecoder().decode(WritingAttachment.self, from: bytes),
                      file.id == id, file.bytes.count <= 300_000, !file.fileName.isEmpty,
                      file.fileName.utf8.count <= 255, file.fileName != ".", file.fileName != "..",
                      !file.fileName.contains("/"), !file.fileName.contains("\\"), !file.fileName.contains("\0"),
                      !file.fileName.hasPrefix("fuminiwa-assistant-feedback-"), try file.value == after else { throw WritingError.invalidEdit }
                if let index {
                    result[index] = file
                } else {
                    result.insert(file, at: min(max(change.position ?? result.count, 0), result.count))
                }
            } else {
                guard let index else { throw WritingError.changedTarget }; result.remove(at: index)
            }
        }
        guard Set(result.map(\.fileName)).count == result.count else { throw WritingError.invalidEdit }
        return WritingMutation(document: newDocument, attachments: result)
    }
}
