import Foundation

/// 作品パッケージに取り込まれた資料ファイル。
///
/// App 側はこの値と `AttachmentManaging` を通して資料を扱い、`.novelpkg` 内の
/// 具体的な配置(`attachments/`)は知らない。
public struct Attachment: Identifiable, Sendable, Equatable {
    /// パッケージ内で一意なファイル名。
    public var fileName: String
    /// ファイルサイズ(バイト)。
    public var byteCount: Int64

    public var id: String {
        fileName
    }

    public init(fileName: String, byteCount: Int64) {
        self.fileName = fileName
        self.byteCount = byteCount
    }
}

/// 資料添付の保存層操作を抽象化するプロトコル。
///
/// `DocumentRepository` とは独立させ、App 側が保存形式の内部構造を直接触らない
/// ための細い入口として使う。
public protocol AttachmentManaging: Sendable {
    /// 指定作品に含まれる資料一覧を返す。
    func listAttachments(in packageURL: URL) async throws -> [Attachment]

    /// 外部ファイルを作品の資料として取り込む。ファイル名が衝突した場合は実装側で一意化する。
    @discardableResult
    func addAttachment(from sourceURL: URL, to packageURL: URL) async throws -> Attachment

    /// 指定ファイル名の資料を削除する。
    func deleteAttachment(named fileName: String, from packageURL: URL) async throws

    /// プレビューなどで参照するための資料URLを返す。
    func attachmentURL(named fileName: String, in packageURL: URL) -> URL
}
