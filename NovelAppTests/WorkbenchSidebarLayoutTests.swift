import AppKit
import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import SwiftUI
import Testing

extension WorkbenchVisualTests {
    @Test("sidebar retains its native list and visible first row across section switches")
    func sidebarSurvivesSectionSwitches() async throws {
        let state = AppState(
            dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready
        )
        let episode = Episode(title: "第一話", content: "サイドバー切替の検証用本文です。")
        let chapter = Chapter(title: "第一章", episodes: [episode])
        state.document = NovelDocument(title: "サイドバー検証", chapters: [chapter], flags: [Flag(title: "未回収", note: "")])
        state.selectedChapterID = chapter.id
        state.selectedEpisodeID = episode.id
        let window = makeWindow(state: state)
        let host = try #require(window.contentView)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.toolbar = nil
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(400))
        let sidebar = try #require(sidebarTable(in: host))
        let scroll = try #require(sidebar.enclosingScrollView)
        let initialOrigin = scroll.contentView.bounds.origin
        let phase = ProcessInfo.processInfo.environment["SIDEBAR_SCREENSHOT_PHASE"] ?? "after"
        try await sidebarSnapshot(
            #require(window.contentView?.superview), path: "/tmp/fuminiwa-sidebar-\(phase)-initial.png"
        )
        let sections: [ProjectSection] = [.settings, .structure, .projectInfo, .plot, .settings, .plot, .structure]
            + ProjectSection.allCases.flatMap { first in ProjectSection.allCases.flatMap { [first, $0] } }
        for (index, section) in sections.enumerated() {
            window.makeFirstResponder(sidebar)
            let row = section == .settings ? 9 : try #require(ProjectSection.allCases.firstIndex(of: section)) + 1
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let current = try #require(sidebarTable(in: host))
            let currentScroll = try #require(current.enclosingScrollView)
            #expect(ObjectIdentifier(current) == ObjectIdentifier(sidebar))
            #expect(abs(currentScroll.contentView.bounds.origin.y - initialOrigin.y) < 1)
            #expect(state.workspaceSelection.section == section)
            #expect(window.firstResponder === sidebar)
            #expect(current.visibleRect.contains(current.rect(ofRow: 1)))
            let rowInWindow = current.convert(current.rect(ofRow: 1), to: nil)
            #expect(rowInWindow.maxY <= window.contentLayoutRect.maxY)
            try checkContentColumn(in: host, section: section)
            if index == 1 || index == 6 {
                try await sidebarSnapshot(
                    #require(window.contentView?.superview), path: "/tmp/fuminiwa-sidebar-\(phase)-\(index).png"
                )
            }
        }
        try await checkSidebarToggle(in: host, sidebar: sidebar)
    }

    private func checkSidebarToggle(in host: NSView, sidebar: NSTableView) async throws {
        let controller = try splitController(in: host)
        controller.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.splitViewItems[0].isCollapsed)
        controller.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.splitViewItems[0].isCollapsed)
        #expect(sidebarDescendants(host).contains { $0 === sidebar })
    }

    private func makeWindow(state: AppState) -> NSWindow {
        let root = NovelWorkbenchView()
            .preferredColorScheme(.light)
            .environment(state)
            .environment(EditorSettings(userDefaults: state.userDefaults))
            .environment(EditorSearchSession())
            .environment(state.editorCommandSession)
            .environment(SnapshotMenuPresenter(appState: state))
            .environment(ExportPresenter(appState: state))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.toolbarStyle = .unified
        return window
    }

    private func sidebarTable(in host: NSView) -> NSTableView? {
        sidebarDescendants(host).compactMap { $0 as? NSTableView }.min {
            $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
        }
    }

    private func splitController(in host: NSView) throws -> NSSplitViewController {
        let split = try #require(sidebarDescendants(host).compactMap { $0 as? NSSplitView }.first {
            ($0.delegate as? NSSplitViewController)?.splitViewItems.count == 3
        })
        return try #require(split.delegate as? NSSplitViewController)
    }

    private func checkContentColumn(in host: NSView, section: ProjectSection) throws {
        let controller = try splitController(in: host)
        let content = controller.splitViewItems[1]
        #expect(content.isCollapsed == (WorkbenchColumnLayout(section: section) == .twoColumn))
        if WorkbenchColumnLayout(section: section) == .threeColumn {
            // macOS glass columns may extend underneath the sidebar. Measure the exposed column.
            let panes = controller.splitView.arrangedSubviews
            let width = panes[1].frame.maxX - panes[0].frame.maxX
            let minimum: CGFloat = section == .worldbuilding ? 200 : ([.structure, .plot].contains(section) ? 224 : 240)
            let maximum: CGFloat = section == .worldbuilding ? 280 : ([.structure, .plot].contains(section) ? 440 : 340)
            #expect(width >= minimum - 1 && width <= maximum + 1, "\(section): width=\(width)")
        }
    }

    private func sidebarDescendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { sidebarDescendants($0) }
    }

    private func sidebarSnapshot(_ view: NSView, path: String) async throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
