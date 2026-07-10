import NovelCore
@testable import NovelWriter
import Testing

@MainActor
struct WorkbenchOverlayStateTests {
    @Test("同じoverlayの再クリックで閉じる")
    func toggleClosesSameOverlay() {
        let state = WorkbenchOverlayState()
        state.toggle(.memo)
        #expect(state.presented == .memo)
        state.toggle(.memo)
        #expect(state.presented == nil)
    }

    @Test("別overlayを開くと前の表示を置き換える")
    func toggleReplacesDifferentOverlay() {
        let state = WorkbenchOverlayState()
        state.toggle(.memo)
        state.toggle(.snapshots)
        #expect(state.presented == .snapshots)
    }

    @Test("この章のカード詳細表示中も同じアイコンで閉じる")
    func plotCardsToggleClosesFromCardDetail() {
        let state = WorkbenchOverlayState()
        let cardID = PlotCardID()
        state.presented = .plotCard(cardID)
        state.toggle(.plotCards)
        #expect(state.presented == nil)
    }

    @Test("この章の一覧表示中は同じアイコンで閉じる")
    func plotCardsToggleClosesFromList() {
        let state = WorkbenchOverlayState()
        state.presented = .plotCards
        state.toggle(.plotCards)
        #expect(state.presented == nil)
    }
}
