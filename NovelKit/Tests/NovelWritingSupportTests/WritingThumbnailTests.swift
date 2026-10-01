import Foundation
import NovelCore
import NovelThumbnail
import NovelWritingSupport
import Testing

@Suite("Writing thumbnail exclusion")
struct WritingThumbnailTests {
    @Test func wholeArrayWriteKeepsPrivateAttachments() throws {
        let document = NovelDocument.newDocument()
        let privateFile = WritingAttachment(id: UUID(), fileName: ThumbnailOwner(.work, document.id).fileName, bytes: Data([7, 8]))
        let publicFile = WritingAttachment(id: UUID(), fileName: "資料.txt", bytes: Data("合成資料".utf8))
        let edit = try WritingEdit(workId: UUID(), documentId: document.id,
                                   changes: [.init(path: ["attachments", publicFile.id.uuidString.lowercased()], before: publicFile.value, after: nil)])
        let result = try edit.applying(to: document, attachments: [publicFile, privateFile], grant: .wholeWork)
        #expect(result.attachments == [privateFile])
        let merged = try WritingThumbnailBoundary.merging([], with: [publicFile, privateFile], from: document, to: document)
        #expect(merged == [privateFile])
    }

    @Test func thumbnailCannotBeCreatedReadReplacedOrImpersonated() throws {
        let document = NovelDocument.newDocument()
        let file = WritingAttachment(id: UUID(), fileName: ThumbnailOwner(.work, document.id).fileName, bytes: Data([7]))
        let create = try WritingEdit(workId: UUID(), documentId: document.id,
                                     changes: [.init(path: ["attachments", file.id.uuidString.lowercased()], before: nil, after: file.value)])
        #expect(throws: WritingError.self) { try create.applying(to: document, attachments: [], grant: .wholeWork) }
        let remove = try WritingEdit(workId: UUID(), documentId: document.id,
                                     changes: [.init(path: ["attachments", file.id.uuidString.lowercased()], before: file.value, after: nil)])
        #expect(throws: WritingError.self) { try remove.applying(to: document, attachments: [file], grant: .wholeWork) }
        var impersonation = file
        impersonation.fileName = "資料.txt"
        #expect(throws: WritingError.self) {
            try WritingThumbnailBoundary.merging([impersonation], with: [file], from: document, to: document)
        }
    }

    @Test func ownerRemovalPreservesExistingOrphansAndOtherOwners() throws {
        let character = Character(name: "合成人物")
        let document = NovelDocument(title: "合成作品", chapters: [], characters: [character])
        let owned = WritingAttachment(id: UUID(), fileName: ThumbnailOwner(.character, character.id.rawValue).fileName, bytes: Data([1]))
        let orphan = WritingAttachment(id: UUID(), fileName: ThumbnailOwner(.character, UUID()).fileName, bytes: Data([2]))
        var updated = document
        updated.characters = []
        let merged = try WritingThumbnailBoundary.merging([], with: [owned, orphan], from: document, to: updated)
        #expect(merged == [orphan])
    }
}
