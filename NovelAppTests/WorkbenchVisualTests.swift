import AppKit
import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import SwiftUI
import Testing

@Suite("Workbench native layout", .serialized)
@MainActor
struct WorkbenchVisualTests {
    @Test("flag note expands with the lower pane instead of retaining a short form height")
    func flagNoteUsesAvailableHeight() async throws {
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults), initialStartupState: .ready)
        let flag = Flag(title: "古い鍵", note: "検証用の伏線メモ")
        state.document = NovelDocument(title: "表示確認用の作品", chapters: [Chapter(title: "第一章")], flags: [flag])
        state.selectedFlagID = flag.id
        let host = NSHostingView(rootView: FlagSectionView(onChapterJump: { _ in }).environment(state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let note = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == flag.note })
        let scroll = try #require(note.enclosingScrollView)
        #expect(scroll.frame.height > 250)
        try await snapshot(host, path: "/tmp/fuminiwa-visual-flags.png")
    }

    @Test("library can render without a network or credential")
    func offlineViewsRender() async throws {
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults))
        let presenter = DocumentPanelPresenter(appState: state)
        let host = NSHostingView(rootView: LibraryWindowView().environment(state).environment(presenter))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try await snapshot(host, path: "/tmp/fuminiwa-visual-library.png")
        #expect(state.authSession == nil)
    }

    @Test("sync remains visible in a crowded native toolbar")
    func synchronizationSurvivesOverflow() async throws {
        guard #available(macOS 26.1, *) else { return }
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        state.saveState = .saved
        state.authUIState = .signedIn(accountID: "test-account")
        state.authSession = makeMacV2Session(accountID: "test-account", fence: "test-fence")
        state.snapshotSyncCurrentWorkAccountState = .active
        state.snapshotSyncV2UIState = SyncUIState(workID: WorkID(UUID()), localDurability: .unsaved,
                                                  remoteProgress: .noChanges, lastTypedResult: .sent)
        let root = Color.clear
            .toolbar(id: "sync-visibility-test-\(UUID())") {
                WorkbenchToolbarContent(overlayState: WorkbenchOverlayState(), requestSync: {},
                                        showsWritingActions: true, isPlotCardRailPresented: .constant(false))
            }
            .environment(state)
            .environment(SnapshotMenuPresenter(appState: state))
            .environment(ExportPresenter(appState: state))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let toolbar = try #require(window.toolbar)
        let syncItem = try #require(toolbar.items.first { $0.itemIdentifier.rawValue.contains("workbench.snapshot.sync") })
        #expect(toolbar.visibleItems?.contains(where: { $0 === syncItem }) == true)
        #expect(syncItem.visibilityPriority > .standard)
        #expect((toolbar.visibleItems?.count ?? 0) < toolbar.items.count)
    }

    @Test("assistant opens beside the editor and closes without replacing its text view")
    func assistantBottomPanelPreservesEditor() async throws {
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults), initialStartupState: .ready)
        let episode = Episode(title: "本文", content: "表示確認用の本文")
        let chapter = Chapter(title: "第一章", episodes: [episode])
        state.document = NovelDocument(title: "下部パネル確認", chapters: [chapter])
        state.selectedChapterID = chapter.id
        state.selectedEpisodeID = episode.id
        let root = NovelWorkbenchView()
            .environment(state)
            .environment(EditorSettings())
            .environment(EditorSearchSession())
            .environment(state.editorCommandSession)
            .environment(SnapshotMenuPresenter(appState: state))
            .environment(ExportPresenter(appState: state))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == episode.content })

        NotificationCenter.default.post(name: .toggleWritingAssistant, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(descendants(host).contains { $0 === editor })
        #expect(host.bounds.maxX - editor.convert(editor.bounds, to: host).maxX >= 300)
        #expect(try #require(editor.enclosingScrollView).bounds.height > 150)
        try await snapshot(host, path: "/tmp/fuminiwa-assistant-bottom.png")
        NotificationCenter.default.post(name: .toggleWritingAssistant, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(descendants(host).contains { $0 === editor })
        #expect(host.bounds.maxX - editor.convert(editor.bounds, to: host).maxX < 100)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func snapshot(_ view: NSView, path: String) async throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
