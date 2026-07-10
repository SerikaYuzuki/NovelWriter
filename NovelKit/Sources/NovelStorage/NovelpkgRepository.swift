import Foundation
import NovelCore

/// `.novelpkg` 形式(フォルダパッケージ)による `DocumentRepository` の実装。
///
/// パッケージ構成(docs/DESIGN.md 4.2):
/// ```text
/// MyNovel.novelpkg/
/// ├── manifest.json                          … 章順・タイトル・日時などのメタデータ
/// ├── chapters/<ChapterID(UUID)>.md           … 章本文のみ(メタデータなし)
/// ├── notes/<ChapterID(UUID)>.md              … 章メモ(空ならファイルなし)
/// └── attachments/                            … 将来の添付ファイル置き場
/// ```
///
/// 設計上の要点:
/// - 章順は `manifest.json` のみが持つ唯一の正(D-003, D-004)。章ファイル名は
///   連番ではなく `ChapterID`(UUID)ベースにし、並べ替えを manifest.json の
///   書き換えだけで完結させる
/// - 保存は一時ディレクトリに完全な形で書き出してから `replaceItemAt` で
///   置換することでアトミックに行う(docs/DESIGN.md 6.4)
/// - 既存パッケージへの上書き保存では、既存の `attachments/` を新しい
///   パッケージへそのまま引き継ぐ(添付ファイルを失わない)
/// - 章ファイルが1つ欠けていても、読み込み全体は失敗させない。欠けた章は
///   空本文として読み込む(データ救出優先)。`manifest.json` に記載の無い
///   `chapters/*.md` は読み込み時に無視する(削除はしない)
public struct NovelpkgRepository: SnapshottingDocumentRepository, DocumentCopyingRepository {
    /// この実装が保存時に書き出す `manifest.json` の `formatVersion`。
    /// 読み込みは v1 / v2 を受理する。
    public static let currentFormatVersion = "2"

    private static let manifestFileName = "manifest.json"
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

    /// `NovelpkgRepository` を作成する。
    public init() {}

    /// 指定した `.novelpkg` パッケージから作品を読み込む。
    ///
    /// - Throws: パッケージやマニフェストが存在しない、あるいはマニフェストが
    ///   壊れている・非対応バージョンの場合は ``NovelpkgError``。
    ///   個々の章本文ファイルが欠けている場合はエラーにせず、空本文として扱う。
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

        let chaptersURL = url.appendingPathComponent(chaptersDirectoryName, isDirectory: true)
        let notesURL = url.appendingPathComponent(notesDirectoryName, isDirectory: true)
        let chapters: [Chapter] = manifest.chapters.map { entry in
            let chapterFileURL = chaptersURL.appendingPathComponent("\(entry.id.uuidString).md")
            let noteFileURL = notesURL.appendingPathComponent("\(entry.id.uuidString).md")
            // 章ファイルが欠けていても読み込み全体は失敗させない(データ救出優先)。
            // 欠けていた場合は空本文として扱う。
            let content = (try? String(contentsOf: chapterFileURL, encoding: .utf8)) ?? ""
            let memo = (try? String(contentsOf: noteFileURL, encoding: .utf8)) ?? ""
            return Chapter(id: ChapterID(rawValue: entry.id), title: entry.title, content: content, memo: memo)
        }

        let characters = try readCharacters(from: url)
        let plotCards = try readPlotCards(from: url, validChapterIDs: Set(chapters.map(\.id)))
        let flags = try readFlags(from: url, validChapterIDs: Set(chapters.map(\.id)))

        return NovelDocument(
            id: manifest.documentID,
            title: manifest.title,
            chapters: chapters,
            characters: characters,
            plotCards: plotCards,
            flags: flags
        )
    }

    private static func isSupportedFormatVersion(_ formatVersion: String) -> Bool {
        formatVersion == "1" || formatVersion == currentFormatVersion
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
    /// chapters/ / attachments/)を書き出す。この時点では最終的な保存先には
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

        let chaptersURL = workingURL.appendingPathComponent(chaptersDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: chaptersURL, withIntermediateDirectories: true)

        try copyUnknownRootItems(from: contentSourceURL, to: workingURL, fileManager: fileManager)

        try preserveAttachments(from: contentSourceURL, to: workingURL, fileManager: fileManager)
        if let snapshotsSourceURL {
            try preserveSnapshotsDirectory(from: snapshotsSourceURL, to: workingURL, fileManager: fileManager)
        }

        // 章本文を書き出す。ファイル名は ChapterID(UUID)ベース(D-003)。
        try writeChapterContents(doc.chapters, into: chaptersURL)
        try writeChapterNotes(doc.chapters, into: workingURL, fileManager: fileManager)
        try writeCharacters(doc.characters, into: workingURL)
        try writePlotCards(doc.plotCards, into: workingURL)
        try writeFlags(doc.flags, into: workingURL)
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

    private static func writeChapterContents(_ chapters: [Chapter], into chaptersURL: URL) throws {
        for chapter in chapters {
            let chapterFileURL = chaptersURL.appendingPathComponent("\(chapter.id.rawValue.uuidString).md")
            try chapter.content.write(to: chapterFileURL, atomically: false, encoding: .utf8)
        }
    }

    private static func writeChapterNotes(
        _ chapters: [Chapter],
        into workingURL: URL,
        fileManager: FileManager
    ) throws {
        let memos = chapters.filter { !$0.memo.isEmpty }
        guard !memos.isEmpty else { return }

        let notesURL = workingURL.appendingPathComponent(notesDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)
        for chapter in memos {
            let noteFileURL = notesURL.appendingPathComponent("\(chapter.id.rawValue.uuidString).md")
            try chapter.memo.write(to: noteFileURL, atomically: false, encoding: .utf8)
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
            chapters: doc.chapters.map { NovelpkgManifest.ChapterEntry(id: $0.id.rawValue, title: $0.title) },
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
            chaptersDirectoryName,
            notesDirectoryName,
            attachmentsDirectoryName,
            snapshotsDirectoryName,
            charactersFileName,
            plotFileName,
            flagsFileName
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
