import Foundation

/// `.novelpkg` パッケージ内 `manifest.json` の構造を表す型。
///
/// 章の並び順を保持する唯一の場所(D-003, D-004)。この `chapters` 配列の
/// 順序がそのまま `NovelDocument.chapters` の順序になる。章本文そのものは
/// 持たず、`chapters/<ChapterEntry.id>.md` を指すだけの軽量なインデックスに徹する。
///
/// この型はパッケージの内部表現であり、`NovelStorage` の外には公開しない
/// (docs/DESIGN.md 9.3: 保存形式の詳細は NovelStorage に閉じ込める)。
struct NovelpkgManifest: Codable, Equatable {
    /// manifest.json 内の1章分のエントリ(章本文は含まない)。
    struct ChapterEntry: Codable, Equatable {
        /// 章の識別子(`chapters/<id>.md` のファイル名と対応する)。
        var id: UUID
        /// 章タイトル。
        var title: String
    }

    /// マニフェストのフォーマットバージョン。将来の破壊的変更に備える。
    var formatVersion: String
    /// 作品の識別子。
    var documentID: UUID
    /// 作品タイトル。
    var title: String
    /// 章の順序付きリスト。配列の順序がそのまま章順になる。
    var chapters: [ChapterEntry]
    /// 作成日時(ISO8601文字列)。
    var createdAt: String
    /// 更新日時(ISO8601文字列)。
    var updatedAt: String
}
