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

/// v3パッケージを、v1の章本文配置(メタデータ・メモファイルなし)へ戻して移行入力を作る。
///
/// v1 の特徴(D-018): `characters.json` / `plot.json` / `flags.json` /
/// `notes/` は存在せず、章エントリに `episodes` を持たない。
func convertPackageToVersionOne(at packageURL: URL, chapterIDs: [ChapterID]) throws {
    let fileManager = FileManager.default
    let episodesURL = packageURL.appendingPathComponent("episodes", isDirectory: true)
    let episodeNotesURL = packageURL.appendingPathComponent("episode-notes", isDirectory: true)
    let chaptersURL = packageURL.appendingPathComponent("chapters", isDirectory: true)
    try fileManager.createDirectory(at: chaptersURL, withIntermediateDirectories: true)

    for chapterID in chapterIDs {
        let fileName = "\(chapterID.rawValue.uuidString).md"
        try fileManager.moveItem(
            at: episodesURL.appendingPathComponent(fileName),
            to: chaptersURL.appendingPathComponent(fileName)
        )
    }
    try? fileManager.removeItem(at: episodesURL)
    // v1 にはメモ・メタデータJSONが一切存在しない。
    try? fileManager.removeItem(at: episodeNotesURL)
    for fileName in ["characters.json", "plot.json", "flags.json"] {
        try? fileManager.removeItem(at: packageURL.appendingPathComponent(fileName))
    }

    let manifestURL = packageURL.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["formatVersion"] = "1"
    let chapters = try #require(json["chapters"] as? [[String: Any]])
    json["chapters"] = chapters.map { chapter in
        var legacyChapter = chapter
        legacyChapter.removeValue(forKey: "episodes")
        return legacyChapter
    }
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: manifestURL)
}
