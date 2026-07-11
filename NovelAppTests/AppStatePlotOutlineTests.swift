import Foundation
import NovelCore
@testable import NovelWriter
import Testing

@MainActor
struct AppStatePlotOutlineTests {
    @Test("初期状態のプロットOutlineは先頭章を選ぶ")
    func initialPlotOutlineSelectsFirstChapter() {
        let state = makeState()

        #expect(state.plotOutlineSelection == state.selectedChapterID.map(PlotOutlineSelection.chapter))
    }

    @Test("未割り当て選択は執筆の章選択を崩さない")
    func selectingUnassignedKeepsWritingChapter() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)

        state.selectPlotOutline(.unassigned)

        #expect(state.plotOutlineSelection == .unassigned)
        #expect(state.selectedChapterID == chapterID)
    }

    @Test("プロットOutlineで章を選ぶと執筆選択も揃う")
    func selectingPlotChapterSyncsWritingSelection() throws {
        let state = makeState()
        let firstChapterID = try #require(state.selectedChapterID)
        state.addChapter()
        let secondChapterID = try #require(state.document.chapters.last?.id)
        #expect(secondChapterID != firstChapterID)
        #expect(state.plotOutlineSelection == .chapter(secondChapterID))
        #expect(state.selectedChapterID == secondChapterID)

        state.selectPlotOutline(.unassigned)
        #expect(state.plotOutlineSelection == .unassigned)
        #expect(state.selectedChapterID == secondChapterID)

        state.selectPlotOutline(.chapter(firstChapterID))
        #expect(state.plotOutlineSelection == .chapter(firstChapterID))
        #expect(state.selectedChapterID == firstChapterID)
    }

    @Test("未割り当てへ追加したカードはchapterIDがnilになる")
    func unassignedLaneAddsCardWithoutChapter() throws {
        let state = makeState()
        state.selectPlotOutline(.unassigned)
        state.addPlotCard(chapterID: nil)

        let card = try #require(state.document.plotCards.last)
        #expect(card.chapterID == nil)
        #expect(state.selectedPlotCardID == card.id)
    }

    @Test("Outline dropは所属章と選択を移動先へ揃える")
    func movingCardFromOutlineUpdatesMembershipAndSelection() throws {
        let state = makeState()
        let firstChapterID = try #require(state.selectedChapterID)
        state.addChapter()
        let secondChapterID = try #require(state.selectedChapterID)
        state.addPlotCard(chapterID: firstChapterID)
        let cardID = try #require(state.selectedPlotCardID)

        let didMove = state.movePlotCardFromOutline(id: cardID, to: .chapter(secondChapterID))

        #expect(didMove)
        #expect(state.document.plotCards.first(where: { $0.id == cardID })?.chapterID == secondChapterID)
        #expect(state.selectedPlotCardID == cardID)
        #expect(state.plotOutlineSelection == .chapter(secondChapterID))
        #expect(state.selectedChapterID == secondChapterID)
    }

    @Test("Outline dropは無効な移動を拒否する")
    func movingCardFromOutlineRejectsInvalidDestinations() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        state.addPlotCard(chapterID: chapterID)
        let cardID = try #require(state.selectedPlotCardID)
        let missingChapterID = ChapterID(rawValue: UUID())
        let missingCardID = PlotCardID(rawValue: UUID())

        #expect(!state.movePlotCardFromOutline(id: cardID, to: .chapter(chapterID)))
        #expect(!state.movePlotCardFromOutline(id: cardID, to: .chapter(missingChapterID)))
        #expect(!state.movePlotCardFromOutline(id: missingCardID, to: .unassigned))
        #expect(state.document.plotCards.first(where: { $0.id == cardID })?.chapterID == chapterID)
    }

    private func makeState() -> AppState {
        let suiteName = "NovelWriterPlotOutline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(
            dependencies: AppDependencies(
                repository: PlotOutlineRepository(),
                userDefaults: defaults,
                fileManager: .default
            )
        )
    }
}

private actor PlotOutlineRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        NovelDocument.newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}
