@testable import FUMINIWA
import NovelCore
import Testing

struct WorkbenchUILayoutTests {
    @Test("作品情報と設定だけが2列レイアウトになる")
    func columnLayoutMatchesEveryProjectSection() {
        #expect(WorkbenchColumnLayout(section: .projectInfo) == .twoColumn)
        #expect(WorkbenchColumnLayout(section: .settings) == .twoColumn)

        for section in ProjectSection.allCases where section != .projectInfo && section != .settings {
            #expect(WorkbenchColumnLayout(section: section) == .threeColumn)
        }
    }

    @Test("Sidebar focusの引継ぎは2列と3列を跨ぐ場合だけ必要になる")
    func sidebarFocusHandoffOnlyCrossesColumnLayouts() {
        #expect(WorkbenchColumnLayout.requiresSidebarFocusHandoff(from: .projectInfo, to: .structure))
        #expect(WorkbenchColumnLayout.requiresSidebarFocusHandoff(from: .structure, to: .settings))
        #expect(!WorkbenchColumnLayout.requiresSidebarFocusHandoff(from: .projectInfo, to: .settings))
        #expect(!WorkbenchColumnLayout.requiresSidebarFocusHandoff(from: .structure, to: .characters))
    }

    @Test("章Disclosureは選択章を初期表示し、利用者が閉じられる")
    func disclosureStartsWithSelectedChapterAndCanCollapse() {
        let first = ChapterID()
        let second = ChapterID()
        var state = OutlineDisclosureState()

        state.reset(chapterIDs: [first, second], revealing: second)

        #expect(!state.isExpanded(first))
        #expect(state.isExpanded(second))

        state.setExpanded(false, for: second)
        #expect(!state.isExpanded(second))
    }

    @Test("追加章と検索一致章は展開し、削除章の状態を残さない")
    func disclosureRevealsNewAndSearchMatchedChapters() {
        let first = ChapterID()
        let added = ChapterID()
        var state = OutlineDisclosureState()
        state.reset(chapterIDs: [first], revealing: first)
        state.setExpanded(false, for: first)

        state.synchronize(chapterIDs: [first, added], revealing: added)

        #expect(!state.isExpanded(first))
        #expect(state.isExpanded(added))

        state.reveal([first])
        #expect(state.isExpanded(first))

        state.synchronize(chapterIDs: [first], revealing: first)
        #expect(!state.expandedChapterIDs.contains(added))
    }

    @Test("保存状態アイコンは現在編集中の話か空章だけに表示する")
    func saveStateIconIsScopedToActiveOutlineRow() {
        let selectedChapter = ChapterID()
        let otherChapter = ChapterID()
        let selectedEpisode = EpisodeID()
        let otherEpisode = EpisodeID()

        #expect(OutlineSaveStateVisibility.episode(selectedEpisode, selectedEpisodeID: selectedEpisode))
        #expect(!OutlineSaveStateVisibility.episode(otherEpisode, selectedEpisodeID: selectedEpisode))
        #expect(!OutlineSaveStateVisibility.chapter(
            selectedChapter,
            selectedChapterID: selectedChapter,
            selectedEpisodeID: selectedEpisode
        ))
        #expect(OutlineSaveStateVisibility.chapter(
            selectedChapter,
            selectedChapterID: selectedChapter,
            selectedEpisodeID: nil
        ))
        #expect(!OutlineSaveStateVisibility.chapter(
            otherChapter,
            selectedChapterID: selectedChapter,
            selectedEpisodeID: nil
        ))
    }
}
