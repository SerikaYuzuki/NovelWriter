import Foundation

public extension Chapter {
    /// 既存Appの移行期間に限って使う、先頭話の本文互換アクセサ。
    /// UI-FIX-2b で EpisodeID ベースの選択へ置き換えた後に撤去する。
    var content: String {
        get { episodes.first?.content ?? "" }
        set {
            if episodes.isEmpty {
                episodes.append(Episode(content: newValue))
            } else {
                episodes[0].content = newValue
            }
        }
    }

    /// 既存Appの移行期間に限って使う、先頭話のメモ互換アクセサ。
    /// UI-FIX-2b で EpisodeID ベースの選択へ置き換えた後に撤去する。
    var memo: String {
        get { episodes.first?.memo ?? "" }
        set {
            if episodes.isEmpty {
                episodes.append(Episode(memo: newValue))
            } else {
                episodes[0].memo = newValue
            }
        }
    }
}
