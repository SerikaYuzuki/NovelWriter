import AppKit
import Foundation
@testable import FUMINIWA
import NovelCore
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
