import Foundation
import NovelCore

public struct ReadableExportFile: Sendable {
    public let path: [String]
    public let bytes: Data
    public init(path: [String], bytes: Data) {
        self.path = path; self.bytes = bytes
    }
}

public extension NovelExporter {
    /// Ordinary Markdown and original material files in a ZIP readable without this app.
    func readableArchive(_ document: NovelDocument, files: [ReadableExportFile] = []) throws -> Data {
        var entries: [DeterministicZIPWriter.Entry] = try [
            .init(path: "本文.md", data: render(document, options: ExportOptions(format: .markdown))),
            .init(path: "資料.md", data: Data(readableMaterials(document).utf8))
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try entries.append(.init(path: "作品データ.json", data: encoder.encode(document)))
        var paths = Set(entries.map(\.path))
        for file in files {
            guard !file.path.isEmpty, file.path.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0")
            }) else { throw ExportError.renderingFailed(format: .markdown, reason: "資料のファイル名を安全に書き出せません") }
            let path = file.path.joined(separator: "/")
            guard paths.insert(path).inserted else { throw ExportError.renderingFailed(format: .markdown, reason: "資料のファイル名が重複しています") }
            entries.append(.init(path: path, data: file.bytes))
        }
        return try DeterministicZIPWriter.archive(entries: entries)
    }

    func exportReadableArchive(_ document: NovelDocument, files: [ReadableExportFile], to destination: URL) throws {
        try AtomicExportWriter.write(readableArchive(document, files: files), to: destination)
    }
}

private func readableMaterials(_ document: NovelDocument) -> String {
    var sections = ["# \(document.title) — 資料", "## あらすじ\n\n\(document.synopsis)"]
    for chapter in document.chapters {
        for episode in chapter.episodes where !episode.memo.isEmpty {
            sections.append("## メモ：\(chapter.title) / \(episode.title)\n\n\(episode.memo)")
        }
    }
    for character in document.characters {
        let fields: [(String, String?)] = [
            ("読み", character.kana), ("役割", character.role), ("年齢", character.age), ("性別", character.gender),
            ("一人称", character.firstPerson), ("二人称", character.secondPerson), ("話し方", character.speechStyle),
            ("外見", character.appearance), ("性格", character.personality), ("背景", character.background), ("メモ", character.memo)
        ]
        let body = fields.compactMap { title, value in value.flatMap { $0.isEmpty ? nil : "### \(title)\n\n\($0)" } }.joined(separator: "\n\n")
        sections.append("## 人物：\(character.name)\n\n\(body)")
    }
    for plot in document.plotCards {
        let chapter = plot.chapterID.flatMap { id in document.chapters.first { $0.id == id }?.title } ?? "指定なし"
        sections.append("## プロット：\(plot.title)\n\n章：\(chapter)\n\n\(plot.memo)")
    }
    for flag in document.flags {
        sections.append("## 伏線：\(flag.title)\n\n\(flag.isResolved ? "回収済み" : "未回収")\n\n\(flag.note)")
    }
    for note in document.worldNotes {
        sections.append("## ノート：\(note.title)\n\n\(note.content)")
    }
    return sections.joined(separator: "\n\n") + "\n"
}
