import Foundation
import NovelCore
@testable import NovelExport
import Testing

@Test func plainTextFixturePreservesOrderAndNormalizesSharedManuscriptRules() throws {
    let document = exportFixture()
    let original = document

    let data = try NovelExporter().render(document, options: ExportOptions(format: .plainText))
    let rendered = try #require(String(bytes: data, encoding: .utf8))
    let expected = """
    【銀河航路】

    ■ 第一章

    ● 出会い

    　冒頭

    # 記法のまま
    次の行😀

    ● 本文

    ■ 無題の章

    ● 記法

    **強調** と ｜漢字《かんじ》

    ■ 空章
    """ + "\n"

    #expect(rendered == expected)
    #expect(document == original)
    #expect(!rendered.contains("出力しないあらすじ"))
    #expect(Array(data.prefix(3)) != [0xEF, 0xBB, 0xBF])
}

@Test func markdownFixtureKeepsUserMarkdownUnescaped() throws {
    let document = exportFixture()

    let data = try NovelExporter().render(document, options: ExportOptions(format: .markdown))
    let rendered = try #require(String(bytes: data, encoding: .utf8))
    let expected = """
    # 銀河航路

    ## 第一章

    ### 出会い

    　冒頭

    # 記法のまま
    次の行😀

    ### 本文

    ## 無題の章

    ### 記法

    **強調** と ｜漢字《かんじ》

    ## 空章
    """ + "\n"

    #expect(rendered == expected)
    #expect(rendered.hasSuffix("\n"))
    #expect(!rendered.hasSuffix("\n\n"))
}

@Test func allWhitespaceHeadingsUseFallbacksWithoutCreatingContent() throws {
    let document = NovelDocument(
        title: " \r\n　\t",
        chapters: [
            Chapter(
                title: "\n　",
                episodes: [Episode(title: "\r\n ", content: "")]
            )
        ]
    )

    let plainData = try NovelExporter().render(document, options: ExportOptions(format: .plainText))
    let markdownData = try NovelExporter().render(document, options: ExportOptions(format: .markdown))
    let plain = try #require(String(bytes: plainData, encoding: .utf8))
    let markdown = try #require(String(bytes: markdownData, encoding: .utf8))

    #expect(plain == "【無題の作品】\n\n■ 無題の章\n\n● 本文\n")
    #expect(markdown == "# 無題の作品\n\n## 無題の章\n\n### 本文\n")
}

@Test func bodyOnlyLosesTrailingLineFeeds() throws {
    let document = NovelDocument(
        title: "改行",
        chapters: [
            Chapter(
                title: "章",
                episodes: [
                    Episode(title: "話", content: "\n　先頭\r\n\r\n中間\r末尾\n\n")
                ]
            )
        ]
    )

    let data = try NovelExporter().render(document, options: ExportOptions(format: .plainText))
    let rendered = try #require(String(bytes: data, encoding: .utf8))

    #expect(rendered == "【改行】\n\n■ 章\n\n● 話\n\n\n　先頭\n\n中間\n末尾\n")
}

@Test func exportFormatProvidesStableFilenameExtensions() {
    #expect(ExportFormat.plainText.filenameExtension == "txt")
    #expect(ExportFormat.markdown.filenameExtension == "md")
    #expect(ExportOptions(format: .plainText) == ExportOptions(format: .plainText))
}

private func exportFixture() -> NovelDocument {
    NovelDocument(
        title: " \n銀河航路\t ",
        synopsis: "出力しないあらすじ",
        chapters: [
            Chapter(
                title: " 第一章 ",
                episodes: [
                    Episode(
                        title: " 出会い ",
                        content: "　冒頭\r\n\r\n# 記法のまま\r次の行😀\n"
                    ),
                    Episode(title: " \n\t", content: "")
                ]
            ),
            Chapter(
                title: "\n　",
                episodes: [
                    Episode(title: "記法", content: "**強調** と ｜漢字《かんじ》")
                ]
            ),
            Chapter(title: "空章", episodes: [])
        ],
        worldNotes: [WorldNote(title: "出力しない世界観", content: "秘密")]
    )
}
