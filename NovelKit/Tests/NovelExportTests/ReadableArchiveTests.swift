import Foundation
import NovelCore
import NovelExport
import Testing

@Test func readableArchiveContainsOrderedManuscriptMaterialsAndOriginalFiles() throws {
    var document = makeEPUBFixture()
    document.characters = [Character(name: "登場人物", memo: "人物の事情", speechStyle: "静かな口調")]
    document.plotCards = [PlotCard(title: "転機", memo: "約束が破られる")]
    document.flags = [Flag(title: "伏線", note: "赤い鍵")]
    document.worldNotes = [WorldNote(title: "世界", content: "冬の町")]
    let bytes = Data([0, 1, 255, 10])
    let zip = try TestZIPArchive(data: NovelExporter().readableArchive(document,
                                                                       files: [ReadableExportFile(path: ["添付", "資料.bin"], bytes: bytes)]))
    #expect(try zip.string(named: "本文.md").contains(document.title))
    let material = try zip.string(named: "資料.md")
    for text in ["登場人物", "人物の事情", "静かな口調", "約束が破られる", "赤い鍵", "冬の町"] {
        #expect(material.contains(text))
    }
    #expect(try zip.data(named: "添付/資料.bin") == bytes)
    #expect(try JSONDecoder().decode(NovelDocument.self, from: zip.data(named: "作品データ.json")) == document)
}

@Test func readableArchiveRejectsUnsafeAndCollidingFilePaths() {
    for path in [["..", "outside"], ["/outside"], ["本文.md"], ["a\\b"]] {
        #expect(throws: ExportError.self) {
            try NovelExporter().readableArchive(makeEPUBFixture(), files: [ReadableExportFile(path: path, bytes: Data())])
        }
    }
}
