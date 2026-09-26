import Foundation
import NovelCore
import NovelWritingSupport
import Testing

struct WritingEditTests {
    let work = UUID()
    @Test func recordTimestampIsRFC3339AndExportsInteropFixture() throws {
        let record = WritingRecord(workId: nil, kind: "prompt", key: "advice", payload: "{\"text\":\"テスト\"}")
        #expect(record.createdAt.hasSuffix("Z"))
        #expect(throws: Never.self) { try Date(record.createdAt, strategy: .iso8601) }
        if let path = ProcessInfo.processInfo.environment["FUMINIWA_ASSISTANT_INTEROP_FIXTURE"] {
            try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func attachmentDeletionUndoReorderAndChangedTarget() throws {
        let doc = NovelDocument.newDocument()
        let files = ["A", "B", "C"].map { WritingAttachment(id: UUID(), fileName: $0 + ".txt", bytes: Data($0.utf8)) }
        let path = ["attachments", files[1].id.uuidString.lowercased()]
        let edit = try WritingEdit(workId: work, documentId: doc.id,
                                   changes: [WritingChange(path: path, before: files[1].value, after: nil)])
            .prepared(for: doc, attachments: files)
        let removed = try edit.applying(to: doc, attachments: files, grant: WritingGrant(paths: [["attachments"]]))
        #expect(removed.attachments.map(\.fileName) == ["A.txt", "C.txt"])
        #expect(try edit.inverse.applying(to: doc, attachments: removed.attachments, grant: .wholeWork).attachments == files)
        var changed = files; changed[1].bytes = Data("手で編集".utf8)
        #expect(throws: WritingError.changedTarget) { try edit.applying(to: doc, attachments: changed, grant: .wholeWork) }
        let order = WritingValue.array(files.map { .string($0.id.uuidString.lowercased()) })
        let reversed = WritingValue.array(files.reversed().map { .string($0.id.uuidString.lowercased()) })
        let reorder = WritingEdit(workId: work, documentId: doc.id, changes: [WritingChange(path: ["attachments"], before: order, after: reversed)])
        #expect(try reorder.applying(to: doc, attachments: changed, grant: .wholeWork).attachments == Array(changed.reversed()))
    }

    private func contentPath(_ document: NovelDocument) -> [String] {
        [
            "chapters",
            document.chapters[0].id.rawValue.uuidString.lowercased(),
            "episodes",
            document.chapters[0].episodes[0].id.rawValue.uuidString.lowercased(),
            "content"
        ]
    }

    @Test func scopeAppendConcurrencyAndUndo() throws {
        var doc = NovelDocument(title: "作品", chapters: [Chapter(title: "章", content: "原文")])
        let path = contentPath(doc)
        let edit = WritingEdit(workId: work, documentId: doc.id, changes: [WritingChange(path: path, before: .string("原文"), after: .string("原文の続き"))])
        let grant = WritingGrant(paths: [path], appendOnly: true)
        #expect(throws: WritingError.outsideGrant) { try edit.applying(to: doc, grant: .readOnly) }
        doc.synopsis = "依頼中に別の場所を変更"
        let after = try edit.applying(to: doc, grant: grant)
        #expect(after.synopsis == doc.synopsis)
        #expect(after.chapters[0].episodes[0].content == "原文の続き")
        #expect(try edit.inverse.applying(to: after, grant: .wholeWork) == doc)
        doc.chapters[0].episodes[0].content = "手で編集"
        #expect(throws: WritingError.changedTarget) { try edit.applying(to: doc, grant: grant) }
        #expect(throws: WritingError.changedTarget) { try edit.inverse.applying(to: doc, grant: .wholeWork) }
    }

    @Test func unrelatedEditsInSameEpisodeAreKeptAndAmbiguousAnchorsReject() throws {
        let text = "先頭" + String(repeating: "。", count: 60) + "変更する場面" + String(repeating: "、", count: 60) + "末尾"
        var doc = NovelDocument(title: "作品", chapters: [Chapter(title: "章", content: text)])
        let edit = WritingEdit(workId: work, documentId: doc.id, changes: [WritingChange(path: contentPath(doc), before: .string(text),
                                                                                         after: .string(text.replacingOccurrences(
                                                                                             of: "変更する場面",
                                                                                             with: "AIが直した場面"
                                                                                         )))])
        doc.chapters[0].episodes[0].content = text.replacingOccurrences(of: "先頭", with: "手で直した先頭")
        let changed = try edit.applying(to: doc, grant: .wholeWork)
        #expect(changed.chapters[0].episodes[0].content.contains("手で直した先頭"))
        #expect(changed.chapters[0].episodes[0].content.contains("AIが直した場面"))
        #expect(try edit.inverse.applying(to: changed, grant: .wholeWork) == doc)
        doc.chapters[0].episodes[0].content = text.replacingOccurrences(of: "変更する場面", with: "手で直した場面")
        #expect(throws: WritingError.changedTarget) { try edit.applying(to: doc, grant: .wholeWork) }
    }

    @Test func appendCannotRewriteExistingProseOrEscapeIntoOtherFields() throws {
        let doc = NovelDocument(title: "作品", chapters: [Chapter(title: "章", content: "原文")])
        let path = contentPath(doc)
        let edit = WritingEdit(workId: work, documentId: doc.id, changes: [WritingChange(path: path, before: .string("原文"), after: .string("改稿"))])
        #expect(throws: WritingError.outsideGrant) { try edit.applying(to: doc, grant: WritingGrant(paths: [path], appendOnly: true)) }
        let title = WritingEdit(
            workId: work,
            documentId: doc.id,
            changes: [WritingChange(path: ["title"], before: .string("作品"), after: .string("変えた"))]
        )
        #expect(throws: WritingError.outsideGrant) { try title.applying(to: doc, grant: WritingGrant(paths: [path])) }
    }

    @Test func CRUDOrderRestoredAndOptionalFields() throws {
        var doc = NovelDocument.newDocument()
        let firstCharacter = Character(name: "A"), middleCharacter = Character(name: "B"), lastCharacter = Character(name: "C")
        doc.characters = [firstCharacter, middleCharacter, lastCharacter]
        let path = ["characters", middleCharacter.id.rawValue.uuidString.lowercased()]
        let before = try WritingValue.document(doc).at(path)
        let deletion = try WritingEdit(workId: work, documentId: doc.id, changes: [WritingChange(path: path, before: before, after: nil)])
            .prepared(for: doc)
        let deleted = try deletion.applying(to: doc, grant: WritingGrant(paths: [["characters"]]))
        #expect(deleted.characters.map(\.name) == ["A", "C"])
        #expect(try deletion.inverse.applying(to: deleted, grant: .wholeWork) == doc)
        let addOptional = WritingEdit(
            workId: work,
            documentId: doc.id,
            changes: [WritingChange(path: path + ["age"], before: nil, after: .string("20"))]
        )
        #expect(try addOptional.applying(to: doc, grant: WritingGrant(paths: [["characters"]])).characters[1].age == "20")
        let bad = WritingEdit(
            workId: work,
            documentId: doc.id,
            changes: [WritingChange(path: path + ["execute"], before: nil, after: .string("run"))]
        )
        #expect(throws: WritingError.invalidEdit) { try bad.applying(to: doc, grant: .wholeWork) }
    }

    @Test func identityOverlapAndDanglingReferencesRejected() throws {
        var doc = NovelDocument.newDocument()
        let chapter = doc.chapters[0]
        doc.plotCards = [PlotCard(title: "P", chapterID: chapter.id)]
        let path = ["chapters", chapter.id.rawValue.uuidString.lowercased()]
        let deletion = try WritingEdit(
            workId: work,
            documentId: doc.id,
            changes: [WritingChange(path: path, before: WritingValue.document(doc).at(path), after: nil)]
        )
        #expect(throws: WritingError.invalidEdit) { try deletion.applying(to: doc, grant: .wholeWork) }
        let identity = WritingEdit(
            workId: work,
            documentId: doc.id,
            changes: [WritingChange(path: ["id"], before: .string(doc.id.uuidString), after: .string(UUID().uuidString))]
        )
        #expect(throws: WritingError.outsideGrant) { try identity.applying(to: doc, grant: .wholeWork) }
        var another = doc; another.id = UUID()
        #expect(throws: WritingError.changedScope) { try deletion.applying(to: another, grant: .wholeWork) }
    }
}
