import Foundation
import NovelCore
import Testing

/// v3パッケージを、v2の章本文 / 章メモ配置へ戻して移行入力を作る。
func convertPackageToVersionTwo(at packageURL: URL, chapterIDs: [ChapterID]) throws {
    let fileManager = FileManager.default
    let episodesURL = packageURL.appendingPathComponent("episodes", isDirectory: true)
    let notesURL = packageURL.appendingPathComponent("episode-notes", isDirectory: true)
    let chaptersURL = packageURL.appendingPathComponent("chapters", isDirectory: true)
    let legacyNotesURL = packageURL.appendingPathComponent("notes", isDirectory: true)
    try fileManager.createDirectory(at: chaptersURL, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: notesURL.path) {
        try fileManager.createDirectory(at: legacyNotesURL, withIntermediateDirectories: true)
    }

    for chapterID in chapterIDs {
        let fileName = "\(chapterID.rawValue.uuidString).md"
        try fileManager.moveItem(
            at: episodesURL.appendingPathComponent(fileName),
            to: chaptersURL.appendingPathComponent(fileName)
        )
        let noteURL = notesURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: noteURL.path) {
            try fileManager.moveItem(at: noteURL, to: legacyNotesURL.appendingPathComponent(fileName))
        }
    }
    try? fileManager.removeItem(at: episodesURL)
    try? fileManager.removeItem(at: notesURL)

    let manifestURL = packageURL.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["formatVersion"] = "2"
    let chapters = try #require(json["chapters"] as? [[String: Any]])
    json["chapters"] = chapters.map { chapter in
        var legacyChapter = chapter
        legacyChapter.removeValue(forKey: "episodes")
        return legacyChapter
    }
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: manifestURL)
}
