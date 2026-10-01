import AppKit
import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelThumbnail
import NovelUI
import SwiftUI
import Testing

/// Captures production views using only the app target's isolated test composition.
@Suite("Visual refresh captures", .serialized)
@MainActor
struct VisualRefreshCaptureTests {
    @Test(arguments: [
        ("01 海辺の便り", "海"),
        ("　１２『雨あがり』", "雨"),
        ("... 42 —", "文"),
        ("", "文"),
        ("A letter", "A")
    ])
    func skipsLeadingNonTitleCharacters(title: String, expected: String) {
        #expect(CoverInitial.character(in: title) == expected)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_VISUAL_CAPTURE"] == "1"))
    func captureLightAndDarkScreens() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/claude-501/visual-refresh-p2b")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let defaults = makeIsolatedTestUserDefaults()
            let episode = Episode(title: "窓辺の手紙", content: "雨が上がると、庭の葉が光っていた。\n机の上には、まだ開いていない手紙がある。")
            let chapter = Chapter(title: "第一章", episodes: [episode])
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            for section in [ProjectSection.characters, .worldbuilding, .plot] {
                let configuration = try TestRuntimeConfiguration(account: nil)
                let state = AppState(dependencies: AppDependencies(
                    userDefaults: defaults,
                    snapshotSyncV2Factory: {
                        try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                    }
                ))
                #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
                await state.bootstrap()
                #expect(await state.createNewV2Document())
                let settings = EditorSettings(userDefaults: defaults, appearanceApplier: { _ in })
                let character = NovelCore.Character(name: "白石 しおり", kana: "しらいし しおり", memo: "古い手紙を集めている。", colorHex: "#5077B0", role: "主人公")
                let note = WorldNote(title: "海辺の図書室", content: "波の音が聞こえる、小さな図書室。\n閉館後も窓辺には明かりが残る。")
                state.document.characters = [character, .init(name: "風間 蓮", kana: "かざま れん", colorHex: "#5B9160", role: "司書")]
                state.document.worldNotes = [note, .init(title: "潮風祭", content: "夏の終わりに開かれる祭り。")]
                state.document.plotCards = [.init(title: "届いた手紙", memo: "差出人のない手紙が届く。しおりは図書室へ向かう。", chapterID: chapter.id),
                                            .init(title: "雨の図書室", memo: "窓辺で見覚えのある筆跡を見つける。", chapterID: chapter.id)]
                state.document.flags = [.init(title: "青い封筒", note: "引き出しの奥に残された封筒。", plantedChapterID: chapter.id),
                                        .init(title: "窓辺の合図", isResolved: true, plantedChapterID: chapter.id)]
                state.selectedCharacterID = character.id
                state.selectedWorldNoteID = note.id
                state.selectedFlagID = state.document.flags.first?.id
                state.selectedPlotCardID = state.document.plotCards.first?.id
                let image = try #require(NSImage(named: "FuminiwaBookSprout"))
                let tiff = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: tiff))
                let bytes = try #require(bitmap.representation(using: .jpeg, properties: [:]))
                for owner in [ThumbnailOwner(.work, state.document.id), ThumbnailOwner(.character, character.id.rawValue), ThumbnailOwner(.worldNote, note.id.rawValue)] {
                    let encoded = try ThumbnailEncoder.encode(bytes, owner: owner)
                    state.snapshotSyncV2Attachments.append(SyncAttachment(attachmentId: UUID(), fileName: owner.fileName, bytes: encoded))
                }
                state.document.title = "雨あがりの書斎"
                state.document.chapters = [chapter]
                state.plotOutlineSelection = .chapter(chapter.id)
                state.selectedChapterID = chapter.id
                state.selectedEpisodeID = episode.id
                state.document.synopsis = "古い家に届いた一通の手紙から、忘れていた季節の記憶が動き始める。"
                state.workspaceSelection = WorkspaceSelection(section: section)
                let name = "\(section.rawValue)-list-detail"
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
                    root.defaultAppStorage(defaults),
                    size: NSSize(width: 1100, height: 800),
                    dark: dark,
                    url: directory.appendingPathComponent("macos-\(name)-\(suffix).png")
                )
                if section == .characters {
                    for kind in [ThumbnailOwner.Kind.character, .worldNote, .work] {
                        try await capture(ThumbnailCropSheet(data: bytes, owner: ThumbnailOwner(kind, UUID()), onSave: { _ in })
                            .preferredColorScheme(scheme), size: NSSize(width: 420, height: 560), dark: dark,
                            url: directory.appendingPathComponent("macos-crop-\(kind.rawValue)-\(suffix).png"))
                    }
                    try await captureShelf(state: state, defaults: defaults, directory: directory, dark: dark)
                }
            }
        }
    }

    private func captureShelf(state: AppState, defaults: UserDefaults, directory: URL, dark: Bool) async throws {
        let work = try #require(state.currentSnapshotSyncV2WorkID)
        #expect(await state.checkpointSnapshotSyncV2(state.document, reason: .explicit, attachments: state.snapshotSyncV2Attachments))
        let importing = WorkID(UUID())
        let failed = WorkID(UUID())
        state.snapshotSyncLibraryWorks = [
            .init(id: work.rawValue, title: "01 海辺の便り", availability: .local, workID: work, remoteProgress: .idle),
            .init(id: UUID(), title: "02 季節の記録", availability: .local, workID: WorkID(UUID()), remoteProgress: .idle),
            .init(id: importing.rawValue, title: "03 はじまりの庭", availability: .remoteOnly, workID: importing, remoteProgress: .idle, accountState: .active),
            .init(id: failed.rawValue, title: "04 雨あがりの書斎", availability: .remoteOnly, workID: failed, remoteProgress: .idle, accountState: .active)
        ]
        state.snapshotSyncV2RemoteOnlyOpeningWorkID = importing
        state.snapshotSyncV2RemoteOnlyOpenStartedAt = Date().addingTimeInterval(-16)
        state.libraryImportPhases[importing] = ImportPhase(receivedBytes: 8_200_000, totalBytes: 19_000_000)
        state.libraryImportFailures[failed] = .retryable(.lostResponse)
        for mode in [ShelfDisplay.grid, .list] {
            defaults.set(mode.rawValue, forKey: "library.display")
            try await capture(LibraryWindowView(observesLibrary: false).environment(state).environment(DocumentPanelPresenter(appState: state))
                .defaultAppStorage(defaults).preferredColorScheme(dark ? .dark : .light),
                size: NSSize(width: 1100, height: 850), dark: dark,
                url: directory.appendingPathComponent("macos-shelf-\(mode.rawValue)-\(dark ? "dark" : "light").png"))
            try await capture(LibraryWindowView(observesLibrary: false).environment(state).environment(DocumentPanelPresenter(appState: state))
                .defaultAppStorage(defaults).preferredColorScheme(dark ? .dark : .light),
                size: NSSize(width: 700, height: 850), dark: dark,
                url: directory.appendingPathComponent("macos-shelf-\(mode.rawValue)-narrow-\(dark ? "dark" : "light").png"))
        }
        state.snapshotSyncV2RemoteOnlyOpeningWorkID = nil
        for mode in [ShelfDisplay.grid, .list] {
            defaults.set(mode.rawValue, forKey: "library.display")
            try await capture(LibraryWindowView(observesLibrary: false).environment(state).environment(DocumentPanelPresenter(appState: state))
                .defaultAppStorage(defaults).preferredColorScheme(dark ? .dark : .light),
                size: NSSize(width: 700, height: 850), dark: dark,
                url: directory.appendingPathComponent("macos-shelf-\(mode.rawValue)-retry-enabled-\(dark ? "dark" : "light").png"))
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
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.toolbar = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["FUMINIWA_EXTERNAL_CAPTURE"] == "1" {
            try? FileManager.default.removeItem(atPath: url.path + ".captured")
            let request = ["windowID": String(window.windowNumber), "path": url.path]
            let requestURL = url.deletingLastPathComponent().appendingPathComponent("capture-request.json")
            try JSONSerialization.data(withJSONObject: request).write(to: requestURL)
            for _ in 0 ..< 600 {
                if FileManager.default.fileExists(atPath: url.path + ".captured") {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(FileManager.default.fileExists(atPath: url.path + ".captured"))
            let capturedData = try Data(contentsOf: url)
            let bitmap = try #require(NSBitmapImageRep(data: capturedData))
            let colors = Set(stride(from: 0, to: bitmap.pixelsWide, by: 32).flatMap { column in
                stride(from: 0, to: bitmap.pixelsHigh, by: 32).compactMap { row in bitmap.colorAt(x: column, y: row)?.description }
            })
            try #require(colors.count > 1, "Window capture must contain rendered content, not a blank frame")
        } else {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: url.deletingLastPathComponent().appendingPathComponent("render-" + url.lastPathComponent))
        }
        #expect(host.bounds.width >= size.width)
    }
}
