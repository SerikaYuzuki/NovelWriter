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

@MainActor
@Suite("Thumbnail screen captures", .serialized)
struct ThumbnailCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_THUMBNAIL_CAPTURE"] == "1"))
    func captureScreens() async throws {
        let directory = URL(fileURLWithPath: "/tmp/fuminiwa-thumbnails")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = try TestRuntimeConfiguration(account: nil)
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(dependencies: AppDependencies(userDefaults: defaults), initialStartupState: .ready)
        state.snapshotSyncV2Application = app
        let character = Character(name: "灯", kana: "あかり", colorHex: "#5077B0", role: "旅の案内人")
        let note = WorldNote(title: "星見の街", content: "夜になると、橋の上に小さな灯りがともる。")
        var document = NovelDocument.newDocument(title: "星を届ける庭")
        document.synopsis = "画像表示の確認に使う合成作品です。"
        document.characters = [character, Character(name: "凪", colorHex: "#5B9160")]
        document.worldNotes = [note, WorldNote(title: "古い地図", content: "合成資料")]
        state.installV2Document(document, workID: WorkID(UUID()), createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let source = try SyntheticThumbnailImage.data()
        for owner in [ThumbnailOwner(.work, document.id), .init(.character, character.id.rawValue), .init(.worldNote, note.id.rawValue)] {
            let data = try ThumbnailEncoder.encode(source, owner: owner)
            state.snapshotSyncV2Attachments.append(.init(attachmentId: UUID(), fileName: owner.fileName, bytes: data))
        }
        await state.reloadAttachments()
        #expect(await state.checkpointSnapshotSyncV2(document))
        _ = try await app.checkpoint(workID: WorkID(UUID()), document: .newDocument(title: "表紙のない合成作品"), reason: .explicit,
                                     documentCreatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        await state.refreshSnapshotLibrary()
        let settings = EditorSettings(userDefaults: defaults, appearanceApplier: { _ in })
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            try await capture(LibraryView().environment(state).environment(state.workspaceModel).environment(DocumentPanelPresenter(appState: state))
                .preferredColorScheme(scheme), name: "shelf-\(suffix)", dark: dark, directory: directory)
            for section in [ProjectSection.projectInfo, .characters, .worldbuilding] {
                state.workspaceSelection = WorkspaceSelection(section: section)
                state.selectedCharacterID = character.id
                state.selectedWorldNoteID = note.id
                let view = NovelWorkbenchView().environment(state).environment(state.workspaceModel).environment(settings)
                    .environment(EditorSearchSession()).environment(state.editorCommandSession)
                    .environment(SnapshotMenuPresenter(appState: state)).environment(ExportPresenter(appState: state))
                    .environment(DocumentPanelPresenter(appState: state)).preferredColorScheme(scheme)
                try await capture(view, name: "\(section.rawValue)-\(suffix)", dark: dark, directory: directory)
            }
            for kind in ThumbnailOwner.Kind.allCases {
                try await capture(ThumbnailCropSheet(data: source, owner: .init(kind, UUID()), onSave: { _ in })
                    .preferredColorScheme(scheme), name: "crop-\(kind.rawValue)-\(suffix)", dark: dark, directory: directory,
                    size: NSSize(width: 420, height: 560))
            }
        }
    }

    private func capture(_ view: some View, name: String, dark: Bool, directory: URL,
                         size: NSSize = NSSize(width: 1100, height: 800)) async throws {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "サムネイル検証（合成データ）"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(size)
        window.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.toolbar = nil; window.close() }
        try await Task.sleep(for: .milliseconds(600))
        let url = directory.appendingPathComponent("macos-\(name).png")
        try? FileManager.default.removeItem(atPath: url.path + ".captured")
        let request = ["windowID": String(window.windowNumber), "path": url.path]
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("mac-request.json"))
        for _ in 0 ..< 300 {
            if FileManager.default.fileExists(atPath: url.path + ".captured") {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(FileManager.default.fileExists(atPath: url.path + ".captured"))
    }
}
