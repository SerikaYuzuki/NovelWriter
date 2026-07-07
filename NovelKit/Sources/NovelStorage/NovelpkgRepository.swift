import Foundation
import NovelCore

/// `.novelpkg` 形式(フォルダパッケージ)による `DocumentRepository` の実装。
///
/// パッケージ構成(docs/DESIGN.md 4.2):
/// ```text
/// MyNovel.novelpkg/
/// ├── manifest.json                          … 章順・タイトル・日時などのメタデータ
/// ├── chapters/<ChapterID(UUID)>.md           … 章本文のみ(メタデータなし)
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
public struct NovelpkgRepository: DocumentRepository {
    /// この実装が読み書きできる `manifest.json` の `formatVersion`。
    public static let currentFormatVersion = "1"

    private static let manifestFileName = "manifest.json"
    private static let chaptersDirectoryName = "chapters"
    private static let attachmentsDirectoryName = "attachments"

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

    // MARK: - Load

    private static func performLoad(from url: URL) throws -> NovelDocument {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NovelpkgError.packageNotFound(url)
        }

        let manifest = try readManifest(at: url, fileManager: fileManager)

        guard manifest.formatVersion == currentFormatVersion else {
            throw NovelpkgError.unsupportedFormatVersion(manifest.formatVersion)
        }

        let chaptersURL = url.appendingPathComponent(chaptersDirectoryName, isDirectory: true)
        let chapters: [Chapter] = manifest.chapters.map { entry in
            let chapterFileURL = chaptersURL.appendingPathComponent("\(entry.id.uuidString).md")
            // 章ファイルが欠けていても読み込み全体は失敗させない(データ救出優先)。
            // 欠けていた場合は空本文として扱う。
            let content = (try? String(contentsOf: chapterFileURL, encoding: .utf8)) ?? ""
            return Chapter(id: ChapterID(rawValue: entry.id), title: entry.title, content: content)
        }

        return NovelDocument(id: manifest.documentID, title: manifest.title, chapters: chapters)
    }

    private static func readManifest(at url: URL, fileManager: FileManager) throws -> NovelpkgManifest {
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

    // MARK: - Save

    private static func performSave(_ doc: NovelDocument, to url: URL) throws {
        let fileManager = FileManager.default
        let parentDirectory = url.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        // 保存先と同じ親ディレクトリに一時作業ディレクトリを作る。同一ボリューム上に
        // 置くことで、末尾の replaceItemAt(またはmoveItem)によるアトミックな
        // 置換が成立する。
        let workingURL = parentDirectory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: true
        )

        do {
            try writePackageContents(of: doc, into: workingURL, existingPackageURL: url, fileManager: fileManager)
        } catch let error as NovelpkgError {
            try? fileManager.removeItem(at: workingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: workingURL)
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }

        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: workingURL)
            } else {
                try fileManager.moveItem(at: workingURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: workingURL)
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }
    }

    /// `workingURL` に、完全な形の `.novelpkg` パッケージ内容(manifest.json /
    /// chapters/ / attachments/)を書き出す。この時点では最終的な保存先(`url`)
    /// には一切触れない(読み取り専用でのみ参照する)ため、書き出し途中に
    /// 失敗しても既存の保存済みパッケージは無傷のまま残る。
    private static func writePackageContents(
        of doc: NovelDocument,
        into workingURL: URL,
        existingPackageURL url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: workingURL, withIntermediateDirectories: true)

        let chaptersURL = workingURL.appendingPathComponent(chaptersDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: chaptersURL, withIntermediateDirectories: true)

        // 既存パッケージがあれば attachments/ をまるごと引き継ぐ。将来の添付機能
        // (資料・画像など)のためのフォルダであり、上書き保存で失ってはならない。
        let attachmentsURL = workingURL.appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
        let existingAttachmentsURL = url.appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: existingAttachmentsURL.path) {
            try fileManager.copyItem(at: existingAttachmentsURL, to: attachmentsURL)
        } else {
            try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        }

        // 章本文を書き出す。ファイル名は ChapterID(UUID)ベース(D-003)。
        for chapter in doc.chapters {
            let chapterFileURL = chaptersURL.appendingPathComponent("\(chapter.id.rawValue.uuidString).md")
            try chapter.content.write(to: chapterFileURL, atomically: false, encoding: .utf8)
        }

        // 既存パッケージがあれば createdAt を引き継ぐ(読み込めない場合は現在時刻で
        // 新規に振り直す。データ救出優先で、ここでは保存自体を失敗させない)。
        let now = ISO8601DateFormatter().string(from: Date())
        let createdAt = (try? readManifest(at: url, fileManager: fileManager))?.createdAt ?? now

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
}
