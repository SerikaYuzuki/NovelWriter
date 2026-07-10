import Foundation

/// `.novelpkg` パッケージ内 `manifest.json` の構造を表す型。
///
/// 章と話の並び順を保持する唯一の場所(D-003, D-004, D-028)。`chapters` と
/// 各 `episodes` の配列順がそのまま表示順になる。本文そのものは持たず、
/// `episodes/<EpisodeEntry.id>.md` を指すだけの軽量なインデックスに徹する。
///
/// この型はパッケージの内部表現であり、`NovelStorage` の外には公開しない
/// (docs/DESIGN.md 9.3: 保存形式の詳細は NovelStorage に閉じ込める)。
struct NovelpkgManifest: Codable, Equatable {
    /// manifest.json 内の1話分のエントリ(本文は含まない)。
    struct EpisodeEntry: Codable, Equatable {
        var id: UUID
        var title: String
    }

    /// manifest.json 内の1章分のエントリ(本文は含まない)。
    struct ChapterEntry: Codable, Equatable {
        var id: UUID
        var title: String
        /// v1 / v2 には存在しない。`nil` は旧形式の章を表す。
        var episodes: [EpisodeEntry]?

        init(id: UUID, title: String, episodes: [EpisodeEntry]? = nil) {
            self.id = id
            self.title = title
            self.episodes = episodes
        }
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
