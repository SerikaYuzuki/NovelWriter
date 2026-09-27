import Foundation
import NovelCore
import NovelSyncV2

/// Read-only Markdown travels through the existing snapshot attachment contract.
struct AssistantFeedback: Identifiable, Equatable, Sendable {
    let id: UUID
    let purpose: AssistantPurpose
    let scopeTitle: String
    let createdAt: Date
    let markdown: String

    private struct Header: Codable {
        var version = 1
        let id: UUID
        let purpose: AssistantPurpose
        let scopeTitle: String
        let createdAt: Date
    }

    var fileName: String {
        "fuminiwa-feedback-\(id.uuidString).md"
    }

    var title: String {
        "\(purpose.rawValue) · \(scopeTitle)"
    }

    func attachment() throws -> SyncAttachment {
        guard purpose != .proofreading, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              markdown.utf8.count <= 8_000_000 else { throw AssistantError.invalidResponse }
        let header = Header(id: id, purpose: purpose, scopeTitle: scopeTitle, createdAt: createdAt)
        let encoded = try JSONEncoder().encode(header).base64EncodedString()
        let bytes = Data("<!-- fuminiwa-feedback-v1 \(encoded) -->\n\n\(markdown)".utf8)
        return SyncAttachment(attachmentId: id, fileName: fileName, bytes: bytes)
    }

    func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(fileName)
        do { try attachment().bytes.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return url
    }

    static func decode(fileName: String, bytes: Data) -> Self? {
        guard fileName.hasPrefix("fuminiwa-feedback-"), fileName.hasSuffix(".md"), bytes.count <= 8_100_000,
              let text = String(data: bytes, encoding: .utf8), let separator = text.range(of: " -->\n\n"),
              text.hasPrefix("<!-- fuminiwa-feedback-v1 "),
              let data = Data(base64Encoded: String(text[text.index(text.startIndex, offsetBy: 26) ..< separator.lowerBound])),
              let header = try? JSONDecoder().decode(Header.self, from: data), header.version == 1,
              header.purpose != .proofreading, header.createdAt.timeIntervalSince1970.isFinite else { return nil }
        let value = Self(id: header.id, purpose: header.purpose, scopeTitle: header.scopeTitle,
                         createdAt: header.createdAt, markdown: String(text[separator.upperBound...]))
        guard value.fileName == fileName, !value.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static func list(_ attachments: [SyncAttachment]) -> [Self] {
        attachments.compactMap { decode(fileName: $0.fileName, bytes: $0.bytes) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
}
