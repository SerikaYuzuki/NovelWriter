import Foundation
import NovelCore

extension NovelpkgRepository {
    static func readChapters(
        from manifest: NovelpkgManifest,
        packageURL: URL,
        fileManager: FileManager
    ) throws -> [Chapter] {
        let episodesURL = packageURL.appendingPathComponent(episodesDirectoryName, isDirectory: true)
        let episodeNotesURL = packageURL.appendingPathComponent(episodeNotesDirectoryName, isDirectory: true)
        let chaptersURL = packageURL.appendingPathComponent(chaptersDirectoryName, isDirectory: true)
        let notesURL = packageURL.appendingPathComponent(notesDirectoryName, isDirectory: true)

        return try manifest.chapters.map { entry in
            let episodeEntries = entry.episodes ?? [
                NovelpkgManifest.EpisodeEntry(id: entry.id, title: Episode.defaultTitle)
            ]
            let isLegacyChapter = entry.episodes == nil
            let contentDirectoryURL = isLegacyChapter ? chaptersURL : episodesURL
            let memoDirectoryURL = isLegacyChapter ? notesURL : episodeNotesURL
            let contentDirectoryName = isLegacyChapter ? chaptersDirectoryName : episodesDirectoryName
            let memoDirectoryName = isLegacyChapter ? notesDirectoryName : episodeNotesDirectoryName

            let episodes = try episodeEntries.map { episodeEntry in
                try readEpisode(
                    entry: episodeEntry,
                    packageURL: packageURL,
                    contentDirectoryURL: contentDirectoryURL,
                    memoDirectoryURL: memoDirectoryURL,
                    contentDirectoryName: contentDirectoryName,
                    memoDirectoryName: memoDirectoryName,
                    fileManager: fileManager
                )
            }
            return Chapter(id: ChapterID(rawValue: entry.id), title: entry.title, episodes: episodes)
        }
    }

    static func readRequiredUTF8Payload(
        at payloadURL: URL,
        relativePath: String,
        packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        guard fileManager.fileExists(atPath: payloadURL.path) else {
            throw NovelpkgError.payloadUnreadable(
                url: packageURL,
                relativePath: relativePath,
                reason: "必須ファイルが見つかりません"
            )
        }

        return try readExistingUTF8Payload(
            at: payloadURL,
            relativePath: relativePath,
            packageURL: packageURL
        )
    }

    static func readOptionalUTF8Payload(
        at payloadURL: URL,
        relativePath: String,
        packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        guard fileManager.fileExists(atPath: payloadURL.path) else { return "" }

        return try readExistingUTF8Payload(
            at: payloadURL,
            relativePath: relativePath,
            packageURL: packageURL
        )
    }

    private static func readExistingUTF8Payload(
        at payloadURL: URL,
        relativePath: String,
        packageURL: URL
    ) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: payloadURL)
        } catch {
            throw NovelpkgError.payloadUnreadable(
                url: packageURL,
                relativePath: relativePath,
                reason: String(describing: error)
            )
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw NovelpkgError.payloadUnreadable(
                url: packageURL,
                relativePath: relativePath,
                reason: "UTF-8 として解釈できません"
            )
        }
        return text
    }

    private static func readEpisode(
        entry: NovelpkgManifest.EpisodeEntry,
        packageURL: URL,
        contentDirectoryURL: URL,
        memoDirectoryURL: URL,
        contentDirectoryName: String,
        memoDirectoryName: String,
        fileManager: FileManager
    ) throws -> Episode {
        let fileName = "\(entry.id.uuidString).md"
        let content = try readRequiredUTF8Payload(
            at: contentDirectoryURL.appendingPathComponent(fileName),
            relativePath: "\(contentDirectoryName)/\(fileName)",
            packageURL: packageURL,
            fileManager: fileManager
        )
        let memo = try readOptionalUTF8Payload(
            at: memoDirectoryURL.appendingPathComponent(fileName),
            relativePath: "\(memoDirectoryName)/\(fileName)",
            packageURL: packageURL,
            fileManager: fileManager
        )
        return Episode(
            id: EpisodeID(rawValue: entry.id),
            title: entry.title,
            content: content,
            memo: memo
        )
    }
}
