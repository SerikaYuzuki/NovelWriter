import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2PortableBridge
import NovelThumbnail
import Testing

@Test func thumbnailBindingSurvivesReassignedAttachmentIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-roundtrip-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = NovelDocument(title: "合成作品", chapters: [], characters: [Character(name: "人物")],
                                 worldNotes: [WorldNote(title: "世界", content: "合成設定")])
    let owners = [ThumbnailOwner(.work, document.id), ThumbnailOwner(.character, document.characters[0].id.rawValue),
                  ThumbnailOwner(.worldNote, document.worldNotes[0].id.rawValue)]
    let attachments = owners.map { SyncAttachment(attachmentId: UUID(), fileName: $0.fileName, bytes: Data([1, 2, 3])) }
    let bridge = SyncV2PortableBridge()
    let url = root.appendingPathComponent("images.novelpkg")
    try await bridge.exportExplicitPackage(document: document, attachments: attachments, documentCreatedAt: Date(timeIntervalSince1970: 1_790_000_000), resources: [], to: url)
    let imported = try await bridge.importExplicitPackage(from: url)
    let originalIDs = Set(attachments.map(\.attachmentId))
    #expect(imported.attachments.allSatisfy { !originalIDs.contains($0.attachmentId) })
    #expect(imported.document == document)
    for attachment in imported.attachments {
        let owner = try #require(ThumbnailOwner(fileName: attachment.fileName))
        #expect(owner.exists(in: imported.document))
        #expect(owners.contains(owner))
        #expect(attachment.bytes == Data([1, 2, 3]))
    }
}
