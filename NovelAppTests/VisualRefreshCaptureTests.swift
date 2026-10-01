import AppKit
import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import SwiftUI
import Testing

/// Captures production views using only the app target's isolated test composition.
@Suite("Visual refresh captures", .serialized)
@MainActor
struct VisualRefreshCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_VISUAL_CAPTURE"] == "1"))
    func captureLightAndDarkScreens() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/claude-501/visual-refresh-p1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let defaults = makeIsolatedTestUserDefaults()
            let episode = Episode(title: "窓辺の手紙", content: "雨が上がると、庭の葉が光っていた。\n机の上には、まだ開いていない手紙がある。")
            let chapter = Chapter(title: "第一章", episodes: [episode])
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            for section in [ProjectSection.structure, .projectInfo, .settings, .characters] {
                let state = AppState(dependencies: AppDependencies(userDefaults: defaults), initialStartupState: .ready)
                let settings = EditorSettings(userDefaults: defaults, appearanceApplier: { _ in })
                state.document = NovelDocument(title: "雨あがりの書斎", chapters: [chapter], flags: [Flag(title: "封筒の差出人")])
                state.selectedChapterID = chapter.id
                state.selectedEpisodeID = episode.id
                state.document.synopsis = "古い家に届いた一通の手紙から、忘れていた季節の記憶が動き始める。"
                state.workspaceSelection = WorkspaceSelection(section: section)
                let name = switch section {
                case .structure: "sidebar"
                case .projectInfo: "work-info"
                case .settings: "settings"
                default: "empty"
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
            let assistant = AssistantPanelView(
                defaults: defaults,
                contextID: "visual-test",
                episodeTitle: episode.title,
                currentEpisodeID: episode.id,
                capture: { throw NSError(domain: "VisualTest", code: 1) },
                close: {}
            )
            .preferredColorScheme(scheme)
            try await capture(
                assistant,
                size: NSSize(width: 420, height: 740),
                dark: dark,
                url: directory.appendingPathComponent("macos-ai-\(suffix).png")
            )
            try await capture(
                ConflictSheet(choose: { _ in }, cancel: {}).preferredColorScheme(scheme),
                size: NSSize(width: 420, height: 440),
                dark: dark,
                url: directory.appendingPathComponent("macos-conflict-\(suffix).png")
            )
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
