import Foundation
import NovelCore
import NovelExport
import NovelSyncV2
import NovelThumbnail

/// This value capture is shared by the platform document-operation gates.
public enum ReadableExport {
    public static func write(_ document: NovelDocument, attachments: [SyncAttachment], resources: [PortableResource], to url: URL) async throws {
        let attachmentFiles = attachments.filter { !ThumbnailOwner.isReserved($0.fileName) }.map {
            ReadableExportFile(path: ["添付", $0.attachmentId.uuidString.lowercased(), $0.fileName], bytes: $0.bytes)
        }
        let resourceFiles = try resources.filter { $0.kind == .regularFile }.map { resource in
            guard let bytes = resource.bytes else {
                throw ExportError.renderingFailed(format: .markdown, reason: "資料の内容を取得できません")
            }
            return ReadableExportFile(path: ["資料ファイル"] + resource.pathComponents, bytes: bytes)
        }
        let files = attachmentFiles + resourceFiles
        try await Task.detached {
            try NovelExporter().exportReadableArchive(document, files: files, to: url)
        }.value
    }
}
