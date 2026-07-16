import Foundation
import NovelCore
@testable import NovelExport
import Testing

@Test func epubContainerMeetsOCFZipRequirements() throws {
    let data = try NovelExporter().render(makeEPUBFixture(), options: ExportOptions(format: .epub))
    let archive = try TestZIPArchive(data: data)
    let expectedPaths = [
        "mimetype",
        "META-INF/container.xml",
        "OEBPS/content.opf",
        "OEBPS/nav.xhtml",
        "OEBPS/styles.css",
        "OEBPS/title.xhtml",
        "OEBPS/chapter-1.xhtml",
        "OEBPS/chapter-2.xhtml",
        "OEBPS/chapter-3.xhtml"
    ]

    #expect(archive.localEntries.map(\.path) == expectedPaths)
    #expect(archive.centralEntries.map(\.path) == expectedPaths)
    #expect(archive.localEntries.allSatisfy { $0.versionNeeded == 20 })
    #expect(archive.localEntries.allSatisfy { $0.compressionMethod == 0 })
    #expect(archive.localEntries.allSatisfy { ($0.flags & 0x0800) != 0 })
    #expect(archive.centralEntries.allSatisfy { $0.compressionMethod == 0 })
    #expect(archive.centralEntries.allSatisfy { ($0.flags & 0x0800) != 0 })
    #expect(
        zip(archive.localEntries, archive.centralEntries).allSatisfy { local, central in
            local.path == central.path
                && UInt32(local.localHeaderOffset) == central.localHeaderOffset
        }
    )

    let mimetype = try #require(archive.localEntries.first)
    #expect(mimetype.path == "mimetype")
    #expect(mimetype.data == Data("application/epub+zip".utf8))
    #expect(mimetype.extraField.isEmpty)
    #expect(mimetype.dataOffset == 38)
    #expect(!mimetype.data.starts(with: [0xEF, 0xBB, 0xBF]))
    #expect(archive.centralDirectoryOffset > mimetype.dataOffset)
    #expect(archive.centralDirectorySize > 0)
}

@Test func epubPackageMetadataManifestAndSpineFollowManuscriptOrder() throws {
    let data = try NovelExporter().render(makeEPUBFixture(), options: ExportOptions(format: .epub))
    let archive = try TestZIPArchive(data: data)
    let container = try archive.string(named: "META-INF/container.xml")
    let package = try archive.string(named: "OEBPS/content.opf")
    let expectedIdentifier = "<dc:identifier id=\"pub-id\">"
        + "urn:uuid:12345678-1234-5678-90ab-cdef12345678"
        + "</dc:identifier>"

    #expect(container.contains("full-path=\"OEBPS/content.opf\""))
    #expect(container.contains("media-type=\"application/oebps-package+xml\""))
    #expect(package.contains("version=\"3.0\" unique-identifier=\"pub-id\""))
    #expect(package.contains(expectedIdentifier))
    #expect(package.contains("<dc:title>宇宙 &amp; &lt;航路&gt; &quot;改題&quot; 😀</dc:title>"))
    #expect(package.contains("<dc:language>ja</dc:language>"))
    #expect(occurrenceCount(of: "property=\"dcterms:modified\"", in: package) == 1)
    #expect(package.contains(">2000-01-01T00:00:00Z</meta>"))
    #expect(
        appearsInOrder(
            [
                "href=\"nav.xhtml\"",
                "href=\"styles.css\"",
                "href=\"title.xhtml\"",
                "href=\"chapter-1.xhtml\"",
                "href=\"chapter-2.xhtml\"",
                "href=\"chapter-3.xhtml\""
            ],
            in: package
        )
    )
    #expect(
        appearsInOrder(
            [
                "idref=\"title-page\"",
                "idref=\"chapter-1\"",
                "idref=\"chapter-2\"",
                "idref=\"chapter-3\""
            ],
            in: package
        )
    )
}

@Test func epubNavigationFollowsChapterAndEpisodeOrder() throws {
    let data = try NovelExporter().render(makeEPUBFixture(), options: ExportOptions(format: .epub))
    let archive = try TestZIPArchive(data: data)
    let navigation = try archive.string(named: "OEBPS/nav.xhtml")

    #expect(occurrenceCount(of: "epub:type=\"toc\"", in: navigation) == 1)
    #expect(navigation.contains("lang=\"ja\" xml:lang=\"ja\""))
    #expect(
        appearsInOrder(
            [
                "href=\"title.xhtml\"",
                "href=\"chapter-1.xhtml\"",
                "href=\"chapter-1.xhtml#episode-1\"",
                "href=\"chapter-1.xhtml#episode-2\"",
                "href=\"chapter-2.xhtml\"",
                "href=\"chapter-3.xhtml\"",
                "href=\"chapter-3.xhtml#episode-1\""
            ],
            in: navigation
        )
    )
    #expect(navigation.contains("宇宙 &amp; &lt;航路&gt; &quot;改題&quot; 😀"))
    #expect(navigation.contains("出会い &quot;A&amp;B&quot; &apos;再会&apos;"))
}

@Test func epubChapterContentEscapesXMLAndPreservesParagraphs() throws {
    let data = try NovelExporter().render(makeEPUBFixture(), options: ExportOptions(format: .epub))
    let archive = try TestZIPArchive(data: data)
    let titlePage = try archive.string(named: "OEBPS/title.xhtml")
    let firstChapter = try archive.string(named: "OEBPS/chapter-1.xhtml")
    let emptyChapter = try archive.string(named: "OEBPS/chapter-2.xhtml")
    let emptyEpisodeChapter = try archive.string(named: "OEBPS/chapter-3.xhtml")

    #expect(titlePage.contains("<h1>宇宙 &amp; &lt;航路&gt; &quot;改題&quot; 😀</h1>"))
    #expect(firstChapter.contains("<h1>第一章 &amp; &lt;始まり&gt;</h1>"))
    #expect(firstChapter.contains("<section id=\"episode-1\">"))
    #expect(firstChapter.contains("<h2>出会い &quot;A&amp;B&quot; &apos;再会&apos;</h2>"))
    #expect(firstChapter.contains("<p>　先頭&lt;&amp;&gt;</p>"))
    #expect(firstChapter.contains("<p class=\"blank\">&#160;</p>"))
    #expect(firstChapter.contains("<p>次の段落 😀</p>"))
    #expect(!firstChapter.contains("\r"))

    #expect(emptyChapter.contains("<h1>無題の章</h1>"))
    #expect(!emptyChapter.contains("<h2>"))
    #expect(!emptyChapter.contains("<p>"))
    #expect(emptyEpisodeChapter.contains("<h1>空話章</h1>"))
    #expect(emptyEpisodeChapter.contains("<h2>空話</h2>"))
    #expect(!emptyEpisodeChapter.contains("<p>"))
    #expect(try archive.string(named: "OEBPS/styles.css").contains("white-space: pre-wrap"))

    for path in archive.localEntries.map(\.path).filter({ $0.hasSuffix(".xhtml") }) {
        #expect(try archive.string(named: path).contains("lang=\"ja\" xml:lang=\"ja\""))
    }
}

@Test func epubRenderingIsDeterministicAndIgnoresNonManuscriptMetadata() throws {
    let document = makeEPUBFixture()
    let exporter = NovelExporter()
    let first = try exporter.render(document, options: ExportOptions(format: .epub))
    let second = try exporter.render(document, options: ExportOptions(format: .epub))
    var metadataChanged = document
    metadataChanged.synopsis = "変更後のあらすじ"
    metadataChanged.worldNotes = [WorldNote(title: "変更", content: "変更")]
    let third = try exporter.render(metadataChanged, options: ExportOptions(format: .epub))

    #expect(first == second)
    #expect(first == third)
}

@Test func epubWithNoChaptersStillHasValidTitleSpineAndNavigationItems() throws {
    let document = NovelDocument(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
        title: "章のない作品",
        chapters: []
    )
    let data = try NovelExporter().render(document, options: ExportOptions(format: .epub))
    let archive = try TestZIPArchive(data: data)
    let package = try archive.string(named: "OEBPS/content.opf")
    let navigation = try archive.string(named: "OEBPS/nav.xhtml")

    #expect(!archive.localEntries.contains(where: { $0.path.contains("chapter-") }))
    #expect(occurrenceCount(of: "<itemref ", in: package) == 1)
    #expect(package.contains("<itemref idref=\"title-page\"/>"))
    #expect(occurrenceCount(of: "<li>", in: navigation) == 1)
    #expect(navigation.contains("<li><a href=\"title.xhtml\">章のない作品</a></li>"))
}

@Test func epubFormatProvidesFilenameExtension() {
    #expect(ExportFormat.epub.filenameExtension == "epub")
}
