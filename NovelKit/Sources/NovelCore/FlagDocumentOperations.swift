import Foundation

public extension NovelDocument {
    /// 空白だけの伏線タイトルを、保存・表示に耐える名前へ正規化する。
    static func normalizedFlagTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の伏線" : trimmed
    }

    /// 末尾に伏線を追加する。
    @discardableResult
    mutating func addFlag(
        title: String,
        note: String = "",
        isResolved: Bool = false,
        plantedChapterID: ChapterID? = nil,
        resolvedChapterID: ChapterID? = nil
    ) -> FlagID {
        let flag = Flag(
            title: Self.normalizedFlagTitle(title),
            note: note,
            isResolved: isResolved,
            plantedChapterID: plantedChapterID,
            resolvedChapterID: resolvedChapterID
        )
        flags.append(flag)
        return flag.id
    }

    /// 指定した伏線を削除する。
    @discardableResult
    mutating func removeFlag(id: FlagID) -> Flag? {
        guard let index = flags.firstIndex(where: { $0.id == id }) else { return nil }
        return flags.remove(at: index)
    }

    /// 伏線を並べ替える。
    mutating func moveFlags(fromOffsets: IndexSet, toOffset: Int) {
        let itemsToMove = fromOffsets.map { flags[$0] }
        for index in fromOffsets.sorted(by: >) {
            flags.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.count(where: { $0 < toOffset })
        let adjustedDestination = toOffset - removedBeforeDestination
        flags.insert(contentsOf: itemsToMove, at: adjustedDestination)
    }

    /// 指定した伏線を更新する。
    mutating func updateFlag(_ flag: Flag) {
        guard let index = flags.firstIndex(where: { $0.id == flag.id }) else { return }
        flags[index] = flag
    }

    /// 指定章に紐付く伏線参照を外す。
    mutating func detachFlags(from chapterID: ChapterID) {
        for index in flags.indices {
            if flags[index].plantedChapterID == chapterID {
                flags[index].plantedChapterID = nil
            }
            if flags[index].resolvedChapterID == chapterID {
                flags[index].resolvedChapterID = nil
            }
        }
    }
}
