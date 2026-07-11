import Foundation
import NovelCore

/// `.novelpkg` 形式(フォルダパッケージ)による `DocumentRepository` の実装。
///
/// パッケージ構成(docs/DESIGN.md 4.2):
/// ```text
/// MyNovel.novelpkg/
/// ├── manifest.json                          … 章順・タイトル・日時などのメタデータ
/// ├── episodes/<EpisodeID(UUID)>.md           … 話本文のみ(メタデータなし)
/// ├── episode-notes/<EpisodeID(UUID)>.md      … 話メモ(空ならファイルなし)
/// └── attachments/                            … 将来の添付ファイル置き場
/// ```
///
/// 設計上の要点:
/// - 章順と章内の話順は `manifest.json` のみが持つ唯一の正(D-003, D-004, D-028)。
///   本文ファイル名は連番ではなく `EpisodeID`(UUID)ベースにする
/// - 保存は一時ディレクトリに完全な形で書き出してから `replaceItemAt` で
///   置換することでアトミックに行う(docs/DESIGN.md 6.4)
/// - 既存パッケージへの上書き保存では、既存の `attachments/` を新しい
///   パッケージへそのまま引き継ぐ(添付ファイルを失わない)
/// - 話ファイルが1つ欠けていても、読み込み全体は失敗させない。欠けた話は
///   空本文として読み込む(データ救出優先)。manifest に記載のない本文は
///   読み込み時に無視する(削除はしない)
public struct NovelpkgRepository: SnapshottingDocumentRepository, DocumentCopyingRepository {
    /// この実装が保存時に書き出す `manifest.json` の `formatVersion`。
    /// 読み込みは v1 / v2 / v3 を受理する。
    public static let currentFormatVersion = "3"

    private static let manifestFileName = "manifest.json"
    private static let episodesDirectoryName = "episodes"
    private static let episodeNotesDirectoryName = "episode-notes"
    // v1 / v2 の読み込みと、v3保存時に既知項目として除外するために残す。
    private static let chaptersDirectoryName = "chapters"
    private static let notesDirectoryName = "notes"
    /// `NovelpkgRepository+Attachments.swift` からも参照するため internal(F-D)。
    static let attachmentsDirectoryName = "attachments"
    /// `NovelpkgRepository+Snapshots.swift` からも参照するため internal。
    static let snapshotsDirectoryName = "snapshots"
    // 以下3つは `NovelpkgRepository+Metadata.swift` からも参照するため internal(F-D)。
    static let charactersFileName = "characters.json"
    static let plotFileName = "plot.json"
    static let flagsFileName = "flags.json"
    static let projectFileName = "project.json"
    static let worldFileName = "world.json"
    static let worldNotesDirectoryName = "world-notes"

    /// `NovelpkgRepository` を作成する。
    public init() {}

    /// 指定した `.novelpkg` パッケージから作品を読み込む。
    ///
    /// - Throws: パッケージやマニフェストが存在しない、あるいはマニフェストが
    ///   壊れている・非対応バージョンの場合は ``NovelpkgError``。
    ///   個々の話本文ファイルが欠けている場合はエラーにせず、空本文として扱う。
    public func load(from url: URL) async throws -> NovelDocument {
        try await Task.detached(priority: .utility) {
            try Self.performLoad(from: url)
        }.value
    }

    /// 指定したURLへ、`.novelpkg` パッケージとしてアトミックに保存する。
    ///
    /// 既に同じ場所にパッケージが存在する場合は、その `attachments/` を
    /// 新しいパッケージへ引き継ぐ。
    public func save(_ doc: NovelDocument, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try Self.performSave(doc, to: url)
        }.value
    }

    /// 元パッケージの資料・スナップショット・未知項目を保ったまま別 URL へ保存する。
    public func saveCopy(_ doc: NovelDocument, from sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try Self.performSave(doc, preservingContentsFrom: sourceURL, to: destinationURL)
        }.value
    }
}

// MARK: - Load

extension NovelpkgRepository {
    static func performLoad(from url: URL) throws -> NovelDocument {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NovelpkgError.packageNotFound(url)
        }

        let manifest = try readManifest(at: url, fileManager: fileManager)

        guard isSupportedFormatVersion(manifest.formatVersion) else {
            throw NovelpkgError.unsupportedFormatVersion(manifest.formatVersion)
        }

        let episodesURL = url.appendingPathComponent(episodesDirectoryName, isDirectory: true)
        let episodeNotesURL = url.appendingPathComponent(episodeNotesDirectoryName, isDirectory: true)
        let chaptersURL = url.appendingPathComponent(chaptersDirectoryName, isDirectory: true)
        let notesURL = url.appendingPathComponent(notesDirectoryName, isDirectory: true)
        let chapters: [Chapter] = manifest.chapters.map { entry in
            let episodeEntries = entry.episodes ?? [
                NovelpkgManifest.EpisodeEntry(id: entry.id, title: Episode.defaultTitle)
            ]
            let isLegacyChapter = entry.episodes == nil
            let episodes = episodeEntries.map { episodeEntry in
                let contentURL: URL
                let memoURL: URL
                if isLegacyChapter {
                    // v1 / v2 は章IDを話IDとして再利用し、読み込みを安定させる。
                    contentURL = chaptersURL.appendingPathComponent("\(episodeEntry.id.uuidString).md")
                    memoURL = notesURL.appendingPathComponent("\(episodeEntry.id.uuidString).md")
                } else {
                    contentURL = episodesURL.appendingPathComponent("\(episodeEntry.id.uuidString).md")
                    memoURL = episodeNotesURL.appendingPathComponent("\(episodeEntry.id.uuidString).md")
                }
                let content = (try? String(contentsOf: contentURL, encoding: .utf8)) ?? ""
                let memo = (try? String(contentsOf: memoURL, encoding: .utf8)) ?? ""
                return Episode(
                    id: EpisodeID(rawValue: episodeEntry.id),
                    title: episodeEntry.title,
                    content: content,
                    memo: memo
                )
            }
            return Chapter(id: ChapterID(rawValue: entry.id), title: entry.title, episodes: episodes)
        }

        let metadata = try readDocumentMetadata(from: url, chapters: chapters)

        return NovelDocument(
            id: manifest.documentID,
            title: manifest.title,
            synopsis: metadata.synopsis,
            chapters: chapters,
            characters: metadata.characters,
            plotCards: metadata.plotCards,
            flags: metadata.flags,
            worldNotes: metadata.worldNotes
        )
    }

    private static func isSupportedFormatVersion(_ formatVersion: String) -> Bool {
        formatVersion == "1" || formatVersion == "2" || formatVersion == currentFormatVersion
    }

    static func readManifest(at url: URL, fileManager: FileManager) throws -> NovelpkgManifest {
        let manifestURL = url.appendingPathComponent(manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw NovelpkgError.manifestMissing(url)
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw NovelpkgError.manifestCorrupted(url: url, reason: String(describing: error))
        }

        do {
            return try JSONDecoder().decode(NovelpkgManifest.self, from: data)
        } catch {
            throw NovelpkgError.manifestCorrupted(url: url, reason: String(describing: error))
        }
    }
}

// MARK: - Save

extension NovelpkgRepository {
    static func performSave(_ doc: NovelDocument, to url: URL) throws {
        try performSave(doc, preservingContentsFrom: url, to: url)
    }

    static func performSave(
        _ doc: NovelDocument,
        preservingContentsFrom sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let parentDirectory = destinationURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        // 保存先と同じ親ディレクトリに一時作業ディレクトリを作る。同一ボリューム上に
        // 置くことで、末尾の replaceItemAt(またはmoveItem)によるアトミックな
        // 置換が成立する。
        let workingURL = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: true
        )

        do {
            try writePackageContents(
                of: doc,
                into: workingURL,
                contentSourceURL: sourceURL,
                snapshotsSourceURL: sourceURL,
                fileManager: fileManager
            )
        } catch let error as NovelpkgError {
            try? fileManager.removeItem(at: workingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: workingURL)
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: workingURL)
            } else {
                try fileManager.moveItem(at: workingURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: workingURL)
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }
    }

    /// `workingURL` に、完全な形の `.novelpkg` パッケージ内容(manifest.json /
    /// episodes/ / attachments/)を書き出す。この時点では最終的な保存先には
    /// 一切触れない(読み取り専用でのみ参照する)ため、書き出し途中に失敗しても
    /// 既存の保存済みパッケージは無傷のまま残る。
    ///
    /// - Parameters:
    ///   - contentSourceURL: 資料・未知項目・`createdAt` の引き継ぎ元。
    ///   - snapshotsSourceURL: 非 `nil` のとき、その URL の `snapshots/` を保持する。
    static func writePackageContents(
        of doc: NovelDocument,
        into workingURL: URL,
        contentSourceURL: URL,
        snapshotsSourceURL: URL?,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: workingURL, withIntermediateDirectories: true)

        let episodesURL = workingURL.appendingPathComponent(episodesDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: episodesURL, withIntermediateDirectories: true)

        try copyUnknownRootItems(from: contentSourceURL, to: workingURL, fileManager: fileManager)

        try preserveAttachments(from: contentSourceURL, to: workingURL, fileManager: fileManager)
        if let snapshotsSourceURL {
            try preserveSnapshotsDirectory(from: snapshotsSourceURL, to: workingURL, fileManager: fileManager)
        }

        // 話本文を書き出す。ファイル名は EpisodeID(UUID)ベース(D-028)。
        try writeEpisodeContents(doc.chapters, into: episodesURL)
        try writeEpisodeNotes(doc.chapters, into: workingURL, fileManager: fileManager)
        try writeCharacters(doc.characters, into: workingURL)
        try writePlotCards(doc.plotCards, into: workingURL)
        try writeFlags(doc.flags, into: workingURL)
        try writeSynopsis(doc.synopsis, into: workingURL)
        try writeWorldNotes(doc.worldNotes, into: workingURL, fileManager: fileManager)
        try writeManifest(
            for: doc,
            into: workingURL,
            existingPackageURL: contentSourceURL,
            fileManager: fileManager
        )
    }

    private static func preserveAttachments(
        from packageURL: URL,
        to workingURL: URL,
        fileManager: FileManager
    ) throws {
        // 既存パッケージがあれば attachments/ をまるごと引き継ぐ。将来の添付機能
        // (資料・画像など)のためのフォルダであり、上書き保存で失ってはならない。
        let attachmentsURL = workingURL.appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
        let existingAttachmentsURL = packageURL.appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: existingAttachmentsURL.path) {
            try fileManager.copyItem(at: existingAttachmentsURL, to: attachmentsURL)
        } else {
            try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        }
    }

    private static func preserveSnapshotsDirectory(
        from packageURL: URL,
        to workingURL: URL,
        fileManager: FileManager
    ) throws {
        let snapshotsURL = workingURL.appendingPathComponent(snapshotsDirectoryName, isDirectory: true)
        let existingSnapshotsURL = packageURL.appendingPathComponent(snapshotsDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: existingSnapshotsURL.path) {
            try fileManager.copyItem(at: existingSnapshotsURL, to: snapshotsURL)
        } else {
            try fileManager.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
        }
    }

    private static func writeEpisodeContents(_ chapters: [Chapter], into episodesURL: URL) throws {
        for chapter in chapters {
            for episode in chapter.episodes {
                let episodeFileURL = episodesURL.appendingPathComponent("\(episode.id.rawValue.uuidString).md")
                try episode.content.write(to: episodeFileURL, atomically: false, encoding: .utf8)
            }
        }
    }

    private static func writeEpisodeNotes(
        _ chapters: [Chapter],
        into workingURL: URL,
        fileManager: FileManager
    ) throws {
        let memos = chapters.flatMap(\.episodes).filter { !$0.memo.isEmpty }
        guard !memos.isEmpty else { return }

        let notesURL = workingURL.appendingPathComponent(episodeNotesDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)
        for episode in memos {
            let noteFileURL = notesURL.appendingPathComponent("\(episode.id.rawValue.uuidString).md")
            try episode.memo.write(to: noteFileURL, atomically: false, encoding: .utf8)
        }
    }

    private static func writeManifest(
        for doc: NovelDocument,
        into workingURL: URL,
        existingPackageURL packageURL: URL,
        fileManager: FileManager
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let createdAt = (try? readManifest(at: packageURL, fileManager: fileManager))?.createdAt ?? now

        let manifest = NovelpkgManifest(
            formatVersion: currentFormatVersion,
            documentID: doc.id,
            title: doc.title,
            chapters: doc.chapters.map { chapter in
                NovelpkgManifest.ChapterEntry(
                    id: chapter.id.rawValue,
                    title: chapter.title,
                    episodes: chapter.episodes.map {
                        NovelpkgManifest.EpisodeEntry(id: $0.id.rawValue, title: $0.title)
                    }
                )
            },
            createdAt: createdAt,
            updatedAt: now
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData: Data
        do {
            manifestData = try encoder.encode(manifest)
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        let manifestURL = workingURL.appendingPathComponent(manifestFileName)
        try manifestData.write(to: manifestURL)
    }

    private static func copyUnknownRootItems(
        from packageURL: URL,
        to workingURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: packageURL.path) else { return }

        let knownRootItemNames: Set<String> = [
            manifestFileName,
            episodesDirectoryName,
            episodeNotesDirectoryName,
            chaptersDirectoryName,
            notesDirectoryName,
            attachmentsDirectoryName,
            snapshotsDirectoryName,
            charactersFileName,
            plotFileName,
            flagsFileName,
            projectFileName,
            worldFileName,
            worldNotesDirectoryName
        ]

        let rootItems = try fileManager.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for itemURL in rootItems where !knownRootItemNames.contains(itemURL.lastPathComponent) {
            try fileManager.copyItem(
                at: itemURL,
                to: workingURL.appendingPathComponent(itemURL.lastPathComponent)
            )
        }
    }
}
