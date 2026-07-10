import Foundation

public extension NovelDocument {
    /// 空白だけのプロットカードタイトルを、保存・表示に耐える名前へ正規化する。
    static func normalizedPlotCardTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題のカード" : trimmed
    }

    /// 末尾にプロットカードを追加する。
    @discardableResult
    mutating func addPlotCard(title: String, memo: String = "", chapterID: ChapterID? = nil) -> PlotCardID {
        let card = PlotCard(title: Self.normalizedPlotCardTitle(title), memo: memo, chapterID: chapterID)
        plotCards.append(card)
        return card.id
    }

    /// 指定したプロットカードを削除する。
    @discardableResult
    mutating func removePlotCard(id: PlotCardID) -> PlotCard? {
        guard let index = plotCards.firstIndex(where: { $0.id == id }) else { return nil }
        return plotCards.remove(at: index)
    }

    /// プロットカードを並べ替える。
    mutating func movePlotCards(fromOffsets: IndexSet, toOffset: Int) {
        let itemsToMove = fromOffsets.map { plotCards[$0] }
        for index in fromOffsets.sorted(by: >) {
            plotCards.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.count(where: { $0 < toOffset })
        let adjustedDestination = toOffset - removedBeforeDestination
        plotCards.insert(contentsOf: itemsToMove, at: adjustedDestination)
    }

    /// 指定したプロットカードを更新する。
    mutating func updatePlotCard(id: PlotCardID, title: String, memo: String, chapterID: ChapterID?) {
        guard let index = plotCards.firstIndex(where: { $0.id == id }) else { return }
        plotCards[index].title = title
        plotCards[index].memo = memo
        plotCards[index].chapterID = chapterID
    }

    /// 1本の配列順を保ったまま、カードを章レーンへ移動する。
    ///
    /// `plotCards` の配列順だけを正とし、レーン内の順序は
    /// 「同じ `chapterID` を持つカードだけを配列順に射影したもの」として扱う。
    mutating func movePlotCard(id: PlotCardID, toChapter chapterID: ChapterID?, before targetID: PlotCardID? = nil) {
        guard let originalIndex = plotCards.firstIndex(where: { $0.id == id }) else { return }

        if targetID == id {
            plotCards[originalIndex].chapterID = chapterID
            return
        }

        var moved = plotCards.remove(at: originalIndex)
        moved.chapterID = chapterID

        let targetIndex = targetID.flatMap { targetID in
            plotCards.firstIndex { $0.id == targetID }
        }
        let insertionIndex: Int = if let targetIndex {
            targetIndex
        } else if let lastInLane = plotCards.lastIndex(where: { $0.chapterID == chapterID }) {
            plotCards.index(after: lastInLane)
        } else {
            plotCards.count
        }

        plotCards.insert(moved, at: insertionIndex)
    }

    /// 指定章に紐付くプロットカードの参照を外す。
    mutating func detachPlotCards(from chapterID: ChapterID) {
        for index in plotCards.indices where plotCards[index].chapterID == chapterID {
            plotCards[index].chapterID = nil
        }
    }
}
