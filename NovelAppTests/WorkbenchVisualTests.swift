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

    @Test("plot detail keeps a usable flag editor below the card board")
    func plotDetailShowsUsableLowerFlagPane() async throws {
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        let flag = Flag(title: "配置確認", note: "下段の伏線メモ")
        state.document = NovelDocument(title: "配置確認", chapters: [Chapter(title: "第一章")], flags: [flag])
        state.selectedFlagID = flag.id
        state.selectPlotOutline(.unassigned)
        state.addPlotCard(chapterID: nil)
        let host = NSHostingView(rootView: PlotAndFlagSplitView(onChapterJump: { _ in }).environment(state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let note = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == flag.note })
        let scroll = try #require(note.enclosingScrollView)
        #expect(scroll.frame.height > 80)
        #expect(scroll.frame.width > 200)
        try await snapshot(host, path: "/tmp/fuminiwa-visual-plot-and-flags.png")
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
                WorkbenchOutlineToolbarContent()
            }
            .environment(state)
            .environment(EditorSearchSession())
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
        #expect(syncItem.paletteLabel == "保存して同期")
        #expect(toolbar.visibleItems?.contains(where: { $0 === syncItem }) == true)
        #expect(syncItem.visibilityPriority > .standard)
        #expect((toolbar.visibleItems?.count ?? 0) < toolbar.items.count)
    }

    @Test("assistant opens beside the editor and closes without replacing its text view")
    func nativeChromeAndAssistantPreserveEditor() async throws {
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults), initialStartupState: .ready)
        let episode = Episode(title: "本文", content: "表示確認用の本文")
        let chapter = Chapter(title: "第一章", episodes: [episode])
        state.document = NovelDocument(title: "執筆画面の作品名", chapters: [chapter])
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
        try await Task.sleep(for: .milliseconds(400))
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == episode.content })
        window.toolbarStyle = .unified
        try await Task.sleep(for: .milliseconds(200))
        let tracking = try #require(window.toolbar?.items.compactMap { $0 as? NSTrackingSeparatorToolbarItem }.last)
        let split = tracking.splitView
        let dividerIndex = 1
        let controller = try #require(split.delegate as? NSSplitViewController)
        let outlineView = controller.splitViewItems[1].viewController.view
        let originalWidth = outlineView.frame.width
        let originalPosition = outlineView.frame.maxX
        let toolbar = try #require(window.toolbar)
        #expect(toolbar.items.compactMap { ($0 as? NSTrackingSeparatorToolbarItem)?.dividerIndex } == [0, 1])
        #expect(toolbar.allowsUserCustomization)
        #expect(toolbar.autosavesConfiguration)
        #expect(toolbar.identifier.hasPrefix("fuminiwa.test.toolbar."))
        let allowed = try #require(toolbar.delegate?.toolbarAllowedItemIdentifiers?(toolbar))
        let actions = toolbar.items.filter { $0.itemIdentifier.rawValue.hasPrefix("workbench.") }
        #expect(actions.count >= 10)
        #expect(actions.allSatisfy { !$0.isNavigational && allowed.contains($0.itemIdentifier) })
        split.setPosition(originalPosition - 100, ofDividerAt: dividerIndex)
        try await Task.sleep(for: .milliseconds(150))
        #expect(outlineView.frame.width < originalWidth - 50)
        #expect(descendants(host).contains { $0 === editor })
        try await snapshot(#require(window.contentView?.superview), path: "/tmp/fuminiwa-toolbar-narrow.png")
        split.setPosition(originalPosition, ofDividerAt: dividerIndex)
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(outlineView.frame.width - originalWidth) < 2)
        #expect(descendants(host).contains { $0 === editor })
        try await snapshot(#require(window.contentView?.superview), path: "/tmp/fuminiwa-toolbar-wide.png")

        NotificationCenter.default.post(name: .toggleWritingAssistant, object: nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(descendants(host).contains { $0 === editor })
        #expect(host.bounds.maxX - editor.convert(editor.bounds, to: host).maxX >= 300)
        #expect(try #require(editor.enclosingScrollView).bounds.height > 150)
        try await snapshot(host, path: "/tmp/fuminiwa-assistant-bottom.png")
        NotificationCenter.default.post(name: .toggleWritingAssistant, object: nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(descendants(host).contains { $0 === editor })
        #expect(host.bounds.maxX - editor.convert(editor.bounds, to: host).maxX < 100)

        let searchID = NSToolbarItem.Identifier("workbench.search")
        let searchIndex = try #require(toolbar.items.firstIndex { $0.itemIdentifier == searchID })
        toolbar.removeItem(at: searchIndex)
        try await Task.sleep(for: .milliseconds(150))
        state.workspaceSelection = WorkspaceSelection(section: .feedback)
        try await Task.sleep(for: .milliseconds(250))
        state.workspaceSelection = WorkspaceSelection(section: .structure)
        try await Task.sleep(for: .milliseconds(250))
        #expect(window.toolbar?.items.contains { $0.itemIdentifier == searchID } == false)
        #expect(window.toolbar?.items.compactMap { ($0 as? NSTrackingSeparatorToolbarItem)?.dividerIndex } == [0, 1])
    }

    @Test("toolbar customization survives window recreation and keeps search movable")
    func customizationSurvivesReopen() async throws {
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        let search = EditorSearchSession()
        let toolbarDefaults = makeIsolatedTestUserDefaults()
        let root = Color.clear
            .background(WorkbenchToolbarPersistence(profile: "writing", defaults: toolbarDefaults))
            .toolbar(id: "customization-reopen-\(UUID())") {
                WorkbenchOutlineToolbarContent()
                WorkbenchToolbarContent(overlayState: WorkbenchOverlayState(), requestSync: {},
                                        showsWritingActions: true, isPlotCardRailPresented: .constant(false))
            }
            .environment(state).environment(search)
            .environment(SnapshotMenuPresenter(appState: state)).environment(ExportPresenter(appState: state))
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 400),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            window.orderFront(nil)
            return window
        }
        let first = makeWindow()
        defer { first.close() }
        try await Task.sleep(for: .milliseconds(250))
        let toolbar = try #require(first.toolbar)
        let ids = toolbar.items.map(\.itemIdentifier)
        let searchIndex = try #require(ids.firstIndex { $0.rawValue == "workbench.search" })
        let assistantIndex = try #require(ids.firstIndex { $0.rawValue == "workbench.writing.assistant" })
        #expect(searchIndex < assistantIndex)
        let searchID = ids[searchIndex]
        let allowed = try #require(toolbar.delegate?.toolbarAllowedItemIdentifiers?(toolbar))
        #expect(allowed.contains(searchID))
        toolbar.removeItem(at: searchIndex)
        toolbar.insertItem(withItemIdentifier: searchID, at: 0)
        try await Task.sleep(for: .milliseconds(150))
        let customized = toolbar.items.map(\.itemIdentifier)
        #expect(customized.first == searchID)
        first.close()
        let second = makeWindow()
        defer { second.close() }
        try await Task.sleep(for: .milliseconds(250))
        #expect(second.toolbar?.items.map(\.itemIdentifier) == customized)
        search.focusSearchField()
        try await Task.sleep(for: .milliseconds(100))
        let field = try #require(second.toolbar?.items.first(where: { $0.itemIdentifier == searchID })?.view)
        #expect(descendants(field).contains { $0 is NSSearchField })
        let index = try #require(second.toolbar?.items.firstIndex { $0.itemIdentifier == searchID })
        second.toolbar?.removeItem(at: index)
        second.close()
        let third = makeWindow()
        defer { third.close() }
        try await Task.sleep(for: .milliseconds(250))
        #expect(third.toolbar?.items.contains { $0.itemIdentifier == searchID } == false)
        third.makeKeyAndOrderFront(nil)
        search.focusSearchField(in: third)
        try await Task.sleep(for: .milliseconds(150))
        #expect(third.toolbar?.items.contains { $0.itemIdentifier == searchID } == true)
    }

    @Test("saved feedback is displayed as read-only dated Markdown", arguments: [380.0, 900.0])
    func feedbackReadingView(width: Double) async throws {
        let record = AssistantFeedback(id: UUID(), purpose: .impressions, scopeTitle: "第一章",
                                       createdAt: Date(timeIntervalSince1970: 1_789_257_600),
                                       markdown: """
                                       # 読後の感想

                                       静かな場面に**緊張感**があります。

                                       ## 印象に残った点

                                       > 言葉が少ないからこそ、感情が伝わる。

                                       1. 会話の距離感
                                       2. 人物の行動

                                       ---

                                       | 観点 | 感想 |
                                       | --- | --- |
                                       | 構成 | 自然な流れ |
                                       | 描写 | 情景が浮かぶ |

                                       ```text
                                       場面 → 選択 → 結果
                                       ```

                                       - [x] 読み終えた
                                       """)
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            if width > 600 {
                AssistantFeedbackList(records: [record], selection: .constant(record.id), delete: { _ in true }).frame(width: 280)
                Divider()
            }
            AssistantFeedbackDetail(record: record)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: width > 600 ? .aqua : .darkAqua)
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(descendants(host).compactMap { $0 as? NSTextView }.allSatisfy { !$0.isEditable })
        try await snapshot(#require(window.contentView?.superview), path: "/tmp/fuminiwa-feedback-reading-\(Int(width)).png")
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
