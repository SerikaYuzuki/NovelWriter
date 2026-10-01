import AppKit
import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2Application
import NovelSyncV2Runtime
import SwiftUI
import Testing

/// Captures production views using only the app target's isolated test composition.
@Suite("Visual refresh captures", .serialized)
@MainActor
struct VisualRefreshCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_VISUAL_CAPTURE"] == "1"))
    func captureLightAndDarkScreens() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/claude-501/visual-refresh-p1b")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let defaults = makeIsolatedTestUserDefaults()
            let episode = Episode(title: "窓辺の手紙", content: "雨が上がると、庭の葉が光っていた。\n机の上には、まだ開いていない手紙がある。")
            let chapter = Chapter(title: "第一章", episodes: [episode])
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            for section in [ProjectSection.projectInfo, .settings, .characters, .worldbuilding, .plot, .references] {
                let configuration = try TestRuntimeConfiguration(account: nil)
                let state = AppState(dependencies: AppDependencies(
                    userDefaults: defaults,
                    snapshotSyncV2Factory: {
                        try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                    }
                ))
                #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
                await state.bootstrap()
                let settings = EditorSettings(userDefaults: defaults, appearanceApplier: { _ in })
                state.document.title = "雨あがりの書斎"
                state.document.chapters = [chapter]
                state.plotOutlineSelection = .chapter(chapter.id)
                state.selectedChapterID = chapter.id
                state.selectedEpisodeID = episode.id
                state.document.synopsis = "古い家に届いた一通の手紙から、忘れていた季節の記憶が動き始める。"
                state.workspaceSelection = WorkspaceSelection(section: section)
                let name = switch section {
                case .structure: "sidebar"
                case .projectInfo: "work-info"
                case .settings: "settings"
                default: "empty-\(section.rawValue)"
                }
                let root = NovelWorkbenchView()
                    .environment(state)
                    .environment(settings)
                    .environment(EditorSearchSession())
                    .environment(state.editorCommandSession)
                    .environment(SnapshotMenuPresenter(appState: state))
                    .environment(ExportPresenter(appState: state))
                    .environment(DocumentPanelPresenter(appState: state))
                    .preferredColorScheme(scheme)
                try await capture(
                    root,
                    size: NSSize(width: 1100, height: 800),
                    dark: dark,
                    url: directory.appendingPathComponent("macos-\(name)-\(suffix).png")
                )
            }
        }
    }

    private func capture(_ view: some View, size: NSSize, dark: Bool, url: URL) async throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.toolbarStyle = .unified
        window.contentView = host
        window.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.toolbar = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        // The MCP driver captures only this exact test window and writes the requested PNG.
        try? FileManager.default.removeItem(atPath: url.path + ".captured")
        let request = ["windowID": String(window.windowNumber), "path": url.path]
        let requestURL = url.deletingLastPathComponent().appendingPathComponent("capture-request.json")
        try JSONSerialization.data(withJSONObject: request).write(to: requestURL)
        for _ in 0 ..< 300 {
            if FileManager.default.fileExists(atPath: url.path + ".captured") {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(FileManager.default.fileExists(atPath: url.path + ".captured"))
        #expect(host.bounds.width >= size.width)
    }
}
