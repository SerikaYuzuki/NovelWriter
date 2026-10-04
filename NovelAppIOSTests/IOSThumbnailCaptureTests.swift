import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2Application
import NovelThumbnail
import NovelUI
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS thumbnail screen captures", .serialized)
struct IOSThumbnailCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_THUMBNAIL_CAPTURE"] == "1"))
    func captureScreens() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url, runtimeComposition: .test(configuration))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)
        let character = Character(name: "灯", kana: "あかり", colorHex: "#5077B0", role: "旅の案内人")
        let note = WorldNote(title: "星見の街", content: "夜になると、橋の上に小さな灯りがともる。")
        store.workspaceModel.document.title = "星を届ける庭"
        store.workspaceModel.document.characters = [character, Character(name: "凪", colorHex: "#5B9160")]
        store.workspaceModel.document.worldNotes = [note, WorldNote(title: "古い地図", content: "合成資料")]
        let source = try SyntheticThumbnailImage.data()
        for owner in [ThumbnailOwner(.work, store.workspaceModel.document.id), .init(.character, character.id.rawValue), .init(.worldNote, note.id.rawValue)] {
            let bytes = try ThumbnailEncoder.encode(source, owner: owner)
            #expect(await store.setThumbnail(bytes, owner: owner, session: session, account: store.snapshotSyncV2AccountScope))
        }
        let app = try #require(store.snapshotSyncV2Application)
        store.workspaceModel.libraryRows = try await app.library().items
        let directory = URL(fileURLWithPath: "/tmp/fuminiwa-thumbnails")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let screens: [(String, AnyView)] = [
                ("shelf", AnyView(IOSLibraryView(store: store, openWork: { _ in }, makeNewDocument: {}).environment(store.workspaceModel))),
                ("work-info", AnyView(IOSProjectInfoView(store: store).environment(store.workspaceModel))),
                ("character-list", AnyView(IOSCharacterFeatureView(store: store).environment(store.workspaceModel))),
                ("character-detail", AnyView(IOSCharacterDetailView(store: store, characterID: character.id, expectedSession: session).environment(store.workspaceModel))),
                ("world-list", AnyView(IOSWorldbuildingFeatureView(store: store).environment(store.workspaceModel))),
                ("world-detail", AnyView(IOSWorldNoteDetailView(store: store, noteID: note.id, expectedSession: session).environment(store.workspaceModel)))
            ]
            for (name, view) in screens {
                try await capture(NavigationStack { view }, name: name, dark: dark, directory: directory)
            }
            for kind in ThumbnailOwner.Kind.allCases {
                try await capture(ThumbnailCropSheet(data: source, owner: .init(kind, UUID()), onSave: { _ in }),
                                  name: "crop-\(kind.rawValue)", dark: dark, directory: directory)
            }
        }
    }

    private func capture(_ view: some View, name: String, dark: Bool, directory: URL) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let root = view.preferredColorScheme(dark ? .dark : .light).tint(FuminiwaColor.accent.color)
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        let suffix = dark ? "dark" : "light"
        let url = directory.appendingPathComponent("ios-\(name)-\(suffix).png")
        try? FileManager.default.removeItem(atPath: url.path + ".captured")
        try JSONSerialization.data(withJSONObject: ["path": url.path]).write(to: directory.appendingPathComponent("ios-request.json"))
        for _ in 0 ..< 300 {
            if FileManager.default.fileExists(atPath: url.path + ".captured") {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(FileManager.default.fileExists(atPath: url.path + ".captured"))
    }
}
