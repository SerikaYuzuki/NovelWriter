import Foundation

enum EPUBDocuments {
    /// 再現可能Dataにするため固定値を使う。実時間は同一原稿のバイト列を変えるため使わない。
    private static let deterministicModifiedDate = "2000-01-01T00:00:00Z"

    static let container = lines([
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">",
        "  <rootfiles>",
        "    <rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/>",
        "  </rootfiles>",
        "</container>"
    ])

    static let styles = lines([
        "@charset \"UTF-8\";",
        "html { writing-mode: horizontal-tb; }",
        "body { font-family: serif; line-height: 1.8; margin: 5%; }",
        "h1 { margin: 0 0 2em; }",
        "h2 { margin: 2em 0 1em; }",
        "p { margin: 0 0 1em; white-space: pre-wrap; }",
        "p.blank { min-height: 1em; }",
        "nav ol { padding-inline-start: 1.5em; }"
    ])

    static func package(_ manuscript: Manuscript) -> String {
        let title = XMLText.escape(manuscript.title)
        let identifier = "urn:uuid:\(manuscript.identifier.uuidString.lowercased())"
        var result = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" "
                + "unique-identifier=\"pub-id\" xml:lang=\"ja\">",
            "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
            "    <dc:identifier id=\"pub-id\">\(identifier)</dc:identifier>",
            "    <dc:title>\(title)</dc:title>",
            "    <dc:language>ja</dc:language>",
            "    <meta property=\"dcterms:modified\">\(deterministicModifiedDate)</meta>",
            "  </metadata>",
            "  <manifest>",
            "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
            "    <item id=\"styles\" href=\"styles.css\" media-type=\"text/css\"/>",
            "    <item id=\"title-page\" href=\"title.xhtml\" media-type=\"application/xhtml+xml\"/>"
        ]
        for index in manuscript.chapters.indices {
            let number = index + 1
            result.append(
                "    <item id=\"chapter-\(number)\" href=\"chapter-\(number).xhtml\" "
                    + "media-type=\"application/xhtml+xml\"/>"
            )
        }
        result.append("  </manifest>")
        result.append("  <spine>")
        result.append("    <itemref idref=\"title-page\"/>")
        for index in manuscript.chapters.indices {
            result.append("    <itemref idref=\"chapter-\(index + 1)\"/>")
        }
        result.append("  </spine>")
        result.append("</package>")
        return lines(result)
    }

    static func navigation(_ manuscript: Manuscript) -> String {
        let title = XMLText.escape(manuscript.title)
        var result = xhtmlStart(title: "目次", includesEPUBNamespace: true)
        result.append("  <body>")
        result.append("    <nav epub:type=\"toc\" id=\"toc\">")
        result.append("      <h1>目次</h1>")
        result.append("      <ol>")
        result.append("        <li><a href=\"title.xhtml\">\(title)</a></li>")
        for (chapterIndex, chapter) in manuscript.chapters.enumerated() {
            let number = chapterIndex + 1
            let chapterTitle = XMLText.escape(chapter.title)
            if chapter.episodes.isEmpty {
                result.append("        <li><a href=\"chapter-\(number).xhtml\">\(chapterTitle)</a></li>")
                continue
            }

            result.append("        <li>")
            result.append("          <a href=\"chapter-\(number).xhtml\">\(chapterTitle)</a>")
            result.append("          <ol>")
            for (episodeIndex, episode) in chapter.episodes.enumerated() {
                let episodeTitle = XMLText.escape(episode.title)
                result.append(
                    "            <li><a href=\"chapter-\(number).xhtml#episode-\(episodeIndex + 1)\">"
                        + "\(episodeTitle)</a></li>"
                )
            }
            result.append("          </ol>")
            result.append("        </li>")
        }
        result.append("      </ol>")
        result.append("    </nav>")
        result.append("  </body>")
        result.append("</html>")
        return lines(result)
    }

    static func titlePage(_ manuscript: Manuscript) -> String {
        let title = XMLText.escape(manuscript.title)
        var result = xhtmlStart(title: manuscript.title, includesEPUBNamespace: false)
        result.append("  <body>")
        result.append("    <main>")
        result.append("      <h1>\(title)</h1>")
        result.append("    </main>")
        result.append("  </body>")
        result.append("</html>")
        return lines(result)
    }

    static func chapterPage(_ chapter: Manuscript.Chapter) -> String {
        let title = XMLText.escape(chapter.title)
        var result = xhtmlStart(title: chapter.title, includesEPUBNamespace: false)
        result.append("  <body>")
        result.append("    <main>")
        result.append("      <section>")
        result.append("        <h1>\(title)</h1>")
        for (episodeIndex, episode) in chapter.episodes.enumerated() {
            result.append("        <section id=\"episode-\(episodeIndex + 1)\">")
            result.append("          <h2>\(XMLText.escape(episode.title))</h2>")
            if let body = episode.body {
                result.append(contentsOf: paragraphs(body).map { "          \($0)" })
            }
            result.append("        </section>")
        }
        result.append("      </section>")
        result.append("    </main>")
        result.append("  </body>")
        result.append("</html>")
        return lines(result)
    }

    private static func xhtmlStart(title: String, includesEPUBNamespace: Bool) -> [String] {
        let epubNamespace = includesEPUBNamespace
            ? " xmlns:epub=\"http://www.idpf.org/2007/ops\""
            : ""
        return [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE html>",
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"\(epubNamespace) lang=\"ja\" xml:lang=\"ja\">",
            "  <head>",
            "    <meta charset=\"utf-8\"/>",
            "    <title>\(XMLText.escape(title))</title>",
            "    <link rel=\"stylesheet\" type=\"text/css\" href=\"styles.css\"/>",
            "  </head>"
        ]
    }

    private static func paragraphs(_ body: String) -> [String] {
        body.components(separatedBy: "\n").map { line in
            line.isEmpty
                ? "<p class=\"blank\">&#160;</p>"
                : "<p>\(XMLText.escape(line))</p>"
        }
    }

    private static func lines(_ values: [String]) -> String {
        values.joined(separator: "\n") + "\n"
    }
}

private enum XMLText {
    static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            guard isValidXMLScalar(scalar.value) else {
                escaped.append("�")
                continue
            }
            switch scalar.value {
            case 0x26:
                escaped.append("&amp;")
            case 0x3C:
                escaped.append("&lt;")
            case 0x3E:
                escaped.append("&gt;")
            case 0x22:
                escaped.append("&quot;")
            case 0x27:
                escaped.append("&apos;")
            default:
                escaped.append(contentsOf: String(scalar))
            }
        }
        return escaped
    }

    private static func isValidXMLScalar(_ value: UInt32) -> Bool {
        value == 0x09
            || value == 0x0A
            || value == 0x0D
            || (0x20 ... 0xD7FF).contains(value)
            || (0xE000 ... 0xFFFD).contains(value)
            || (0x10000 ... 0x10FFFF).contains(value)
    }
}
