import Foundation

struct EPUBRenderer {
    private static let mediaType = "application/epub+zip"

    func render(_ manuscript: Manuscript) throws -> Data {
        var entries: [DeterministicZIPWriter.Entry] = [
            entry(path: "mimetype", contents: Self.mediaType),
            entry(path: "META-INF/container.xml", contents: EPUBDocuments.container),
            entry(path: "OEBPS/content.opf", contents: EPUBDocuments.package(manuscript)),
            entry(path: "OEBPS/nav.xhtml", contents: EPUBDocuments.navigation(manuscript)),
            entry(path: "OEBPS/styles.css", contents: EPUBDocuments.styles),
            entry(path: "OEBPS/title.xhtml", contents: EPUBDocuments.titlePage(manuscript))
        ]

        entries.append(contentsOf: manuscript.chapters.enumerated().map { index, chapter in
            entry(
                path: "OEBPS/chapter-\(index + 1).xhtml",
                contents: EPUBDocuments.chapterPage(chapter)
            )
        })
        return try DeterministicZIPWriter.archive(entries: entries)
    }

    private func entry(path: String, contents: String) -> DeterministicZIPWriter.Entry {
        DeterministicZIPWriter.Entry(path: path, data: Data(contents.utf8))
    }
}
