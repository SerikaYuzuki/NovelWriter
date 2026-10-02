import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelThumbnail
import NovelUI
import SwiftUI
import Testing
import UIKit

@Suite("iOS visual refresh captures", .serialized)
@MainActor
struct IOSVisualRefreshCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_VISUAL_CAPTURE"] == "1"))
    func captureLightAndDarkScreens() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url,
                                     runtimeComposition: .test(configuration))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let character = NovelCore.Character(name: "白石 しおり", kana: "しらいし しおり", memo: "古い手紙を集めている。",
                                            colorHex: "#5077B0", role: "主人公", firstPerson: "私", personality: "静かだが好奇心は強い。")
        let note = WorldNote(title: "海辺の図書室", content: "波の音が聞こえる、小さな図書室。\n閉館後も窓辺には明かりが残る。")
        store.document.title = "01 海辺の便り"
        store.document.synopsis = "古い家に届いた一通の手紙から、忘れていた季節の記憶が動き始める。"
        store.document.chapters[0].episodes[0].content = "雨が上がると、庭の葉が光っていた。"
        store.document.characters = [character, .init(name: "風間 蓮", kana: "かざま れん", colorHex: "#5B9160", role: "司書")]
        store.document.worldNotes = [note, .init(title: "潮風祭", content: "夏の終わりに開かれる祭り。")]
        store.document.plotCards = [
            .init(title: "届いた手紙", memo: "差出人のない手紙が届く。\nしおりは図書室へ向かう。"),
            .init(title: "雨の図書室", memo: "窓辺で、見覚えのある筆跡を見つける。"),
            .init(title: "最後の便り", memo: "季節が変わる前に、返事を書く。")
        ]
        store.document.flags = [.init(title: "青い封筒", note: "引き出しの奥に残された封筒。"),
                                .init(title: "窓辺の合図", note: "灯りの意味が分かる。", isResolved: true)]
        let image = try #require(UIImage(named: "FuminiwaBookSprout"))
        let bytes = try #require(image.jpegData(compressionQuality: 0.8))
        let session = try #require(store.currentDocumentSessionToken)
        for owner in [ThumbnailOwner(.work, store.document.id), ThumbnailOwner(.character, character.id.rawValue), ThumbnailOwner(.worldNote, note.id.rawValue)] {
            let encoded = try ThumbnailEncoder.encode(bytes, owner: owner)
            #expect(await store.setThumbnail(encoded, owner: owner, session: session, account: store.snapshotSyncV2AccountScope))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("visual-refresh-p2b")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for large in [false, true] {
                let suffix = "\(dark ? "dark" : "light")-\(large ? "ax1" : "default")"
                let screens: [(String, AnyView)] = [
                    ("work-home", AnyView(NavigationStack { IOSProjectHomeView(store: store, openWriting: {}, openProjectInfo: {}, openPlot: {},
                                                                               openCharacters: {}, openWorldbuilding: {}, openFeedback: {}, openReferences: {}, openSettings: {}) })),
                    ("work-info", AnyView(NavigationStack { IOSProjectInfoView(store: store) })),
                    ("characters-list", AnyView(NavigationStack { IOSCharacterFeatureView(store: store) })),
                    ("character-detail", AnyView(NavigationStack { IOSCharacterDetailView(store: store, characterID: character.id, expectedSession: session) })),
                    ("world-list", AnyView(NavigationStack { IOSWorldbuildingFeatureView(store: store) })),
                    ("world-detail", AnyView(NavigationStack { IOSWorldNoteDetailView(store: store, noteID: note.id, expectedSession: session) })),
                    ("plot-iphone-flags", AnyView(NavigationStack { IOSPlotFeatureView(store: store) }.environment(\.horizontalSizeClass, .compact))),
                    ("plot-ipad-flags", AnyView(NavigationStack { IOSPlotFeatureView(store: store) }.environment(\.horizontalSizeClass, .regular))),
                    ("crop-circle", AnyView(ThumbnailCropSheet(data: bytes, owner: ThumbnailOwner(.character, character.id.rawValue), onSave: { _ in }))),
                    ("crop-square", AnyView(ThumbnailCropSheet(data: bytes, owner: ThumbnailOwner(.worldNote, note.id.rawValue), onSave: { _ in }))),
                    ("crop-cover", AnyView(ThumbnailCropSheet(data: bytes, owner: ThumbnailOwner(.work, store.document.id), onSave: { _ in })))
                ]
                for (name, view) in screens {
                    try await capture(view.preferredColorScheme(dark ? .dark : .light)
                        .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
                        .tint(FuminiwaColor.accent.color).defaultAppStorage(defaults),
                        size: CGSize(width: name.contains("ipad") ? 1024 : 440, height: 956), dark: dark,
                        url: directory.appendingPathComponent("ios-\(name)-\(suffix).png"))
                }
                try await captureShelf(store: store, defaults: defaults, directory: directory, dark: dark, large: large)
            }
        }
        print("VISUAL_CAPTURE_DIRECTORY=\(directory.path)")
    }

    private func captureShelf(store: IOSDocumentStore, defaults: UserDefaults, directory: URL, dark: Bool, large: Bool) async throws {
        let work = try #require(store.syncV2ActiveWorkID)
        let importing = WorkID(UUID())
        let failed = WorkID(UUID())
        store.syncV2LibraryItems = [
            .init(workID: work, title: "01 海辺の便り", availability: .localOnly, accountState: .unbound),
            .init(workID: WorkID(UUID()), title: "02 季節の記録", availability: .localOnly, accountState: .unbound),
            .init(workID: importing, title: "03 はじまりの庭", availability: .remoteOnly, accountState: .active),
            .init(workID: failed, title: "04 雨あがりの書斎", availability: .remoteOnly, accountState: .active)
        ]
        store.snapshotSyncV2RemoteOnlyOpeningWorkID = importing
        store.snapshotSyncV2RemoteOnlyOpenStartedAt = Date().addingTimeInterval(-16)
        store.libraryImportPhases[importing] = ImportPhase(receivedBytes: 8_200_000, totalBytes: 19_000_000)
        store.libraryImportFailures[failed] = .retryable(.lostResponse)
        for mode in [ShelfDisplay.grid, .list] {
            defaults.set(mode.rawValue, forKey: "library.display")
            let root = NavigationStack { IOSLibraryView(store: store, openWork: { _ in }, makeNewDocument: {}, observesLibrary: false) }
                .defaultAppStorage(defaults).preferredColorScheme(dark ? .dark : .light)
                .environment(\.dynamicTypeSize, large ? .accessibility1 : .large).tint(FuminiwaColor.accent.color)
            let suffix = "\(dark ? "dark" : "light")-\(large ? "ax1" : "default")"
            try await capture(root, size: CGSize(width: 440, height: 1200), dark: dark,
                              url: directory.appendingPathComponent("ios-shelf-\(mode.rawValue)-\(suffix).png"))
        }
        store.snapshotSyncV2RemoteOnlyOpeningWorkID = nil
        for mode in [ShelfDisplay.grid, .list] {
            defaults.set(mode.rawValue, forKey: "library.display")
            let root = NavigationStack { IOSLibraryView(store: store, openWork: { _ in }, makeNewDocument: {}, observesLibrary: false) }
                .defaultAppStorage(defaults).preferredColorScheme(dark ? .dark : .light)
                .environment(\.dynamicTypeSize, large ? .accessibility1 : .large).tint(FuminiwaColor.accent.color)
            try await capture(root, size: CGSize(width: 440, height: 1200), dark: dark,
                              url: directory.appendingPathComponent("ios-shelf-\(mode.rawValue)-retry-enabled-\(dark ? "dark" : "light")-\(large ? "ax1" : "default").png"))
        }
        store.libraryImportFailures = [:]
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func capture(_ view: some View, size: CGSize, dark: Bool, url: URL) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(450))
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let data = try #require(image.pngData())
        try data.write(to: url)
        if let scroll = scrollViews(in: host.view).max(by: { $0.contentSize.height < $1.contentSize.height }),
           scroll.contentSize.height > scroll.bounds.height + 80 {
            let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await Task.sleep(for: .milliseconds(150))
            let lower = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let lowerData = try #require(lower.pngData())
            try lowerData.write(to: url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-bottom.png"))
        }
        #expect(host.view.bounds.width > 0)
    }
}
