import AppKit
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
