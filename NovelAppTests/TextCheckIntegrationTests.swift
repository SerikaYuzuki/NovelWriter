import AppKit
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelTextAnalysis
import SwiftUI
import Testing

@MainActor
struct TextCheckIntegrationTests {
    @Test func resultJumpAndReplacementPrefillPreserveManuscript() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        var document = NovelDocument.newDocument()
        document.chapters = [Chapter(title: "章", episodes: [
            Episode(title: "一", content: "　出来る。出来る。"), Episode(title: "二", content: "　できる。…")
        ])]
        #expect(state.installV2Document(document, workID: WorkID(UUID()), createdAt: Date()))
        #expect(await state.checkpointSnapshotSyncV2(document))
        await state.presentTextCheck()
        #expect(state.textCheck.isPresented)
        #expect(!state.workSearch.isPresented)
        await state.runTextCheck()
        let variation = try #require(state.textCheck.results.first { $0.rule == .dictionaryVariation })
        let occurrence = try #require(variation.occurrences.last)
        let editorSearch = EditorSearchSession(), scope = state.workSearchScope
        #expect(await state.selectWorkTextMatch(occurrence.result, match: occurrence.match, expectedScope: scope, editorSearch: editorSearch))
        #expect(state.selectedEpisodeID == occurrence.result.id)
        #expect(editorSearch.selectionRequest?.range == occurrence.match.range)
        let host = NSHostingView(rootView: EditorPaneView().environment(state)
            .environment(EditorSettings(userDefaults: makeIsolatedTestUserDefaults(), appearanceApplier: { _ in }))
            .environment(editorSearch).environment(state.editorCommandSession))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let textView = try #require(findTextView(host))
        #expect(textView.selectedRange() == occurrence.match.range)
        #expect(await state.presentTextCheckReplacement(variation))
        #expect(state.workSearch.query == "できる")
        #expect(state.workSearch.replacement == "出来る")
        #expect(state.workSearch.isPresented)
        #expect(!state.textCheck.isPresented)
        #expect(state.document == document)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(textView.isEditable)
        textView.insertText("変わった", replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        #expect(textView.string == "変わった")
        #expect(await !(state.selectWorkTextMatch(occurrence.result, match: occurrence.match, expectedScope: scope, editorSearch: editorSearch)))
        state.snapshotSyncV2AccountScopeGeneration &+= 1
        #expect(await !(state.selectWorkTextMatch(occurrence.result, match: occurrence.match, expectedScope: scope, editorSearch: editorSearch)))
        #expect(await !(state.presentTextCheckReplacement(variation)))
    }

    private func findTextView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView {
            return text
        }
        return view.subviews.lazy.compactMap { findTextView($0) }.first
    }
}
