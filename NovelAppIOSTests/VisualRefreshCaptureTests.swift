import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2Application
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
        let store = IOSDocumentStore(
            userDefaults: defaults,
            libraryRoot: configuration.localRoot.url,
            runtimeComposition: .test(configuration)
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        store.updateDocumentTitle("雨あがりの書斎")
        store.updateDocumentSynopsis("古い家に届いた一通の手紙から、忘れていた季節の記憶が動き始める。")
        store.document.chapters[0].episodes[0].content = "雨が上がると、庭の葉が光っていた。"
        store.document.flags = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("visual-refresh-p1b")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            let screens: [(String, AnyView)] = [
                ("work-info", AnyView(NavigationStack { IOSProjectInfoView(store: store) })),
                ("settings", AnyView(NavigationStack { IOSSettingsView(store: store, userDefaults: defaults) })),
                (
                    "sidebar",
                    AnyView(NavigationStack {
                        IOSRegularProjectSidebar(store: store, selection: .constant(.projectInfo))
                    })
                ),
                ("empty-characters", AnyView(NavigationStack { IOSCharacterFeatureView(store: store) })),
                ("empty-worldbuilding", AnyView(NavigationStack { IOSWorldbuildingFeatureView(store: store) })),
                ("empty-plot", AnyView(NavigationStack { IOSPlotFeatureView(store: store) })),
                ("empty-references", AnyView(NavigationStack { IOSReferencesFeatureView(store: store) })),
                ("work-home", AnyView(NavigationStack {
                    IOSProjectHomeView(
                        store: store,
                        openWriting: {}, openProjectInfo: {}, openPlot: {}, openCharacters: {},
                        openWorldbuilding: {}, openFeedback: {}, openReferences: {}, openSettings: {}
                    )
                }))
            ]
            for (name, view) in screens {
                try await capture(
                    view.preferredColorScheme(scheme).tint(FuminiwaColor.accent.color).defaultAppStorage(defaults),
                    dark: dark,
                    url: directory.appendingPathComponent("ios-\(name)-\(suffix).png")
                )
            }
        }
        print("VISUAL_CAPTURE_DIRECTORY=\(directory.path)")
    }

    private func capture(_ view: some View, dark: Bool, url: URL) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        // The taller home capture includes the export rows below the initial viewport.
        let height: CGFloat = url.lastPathComponent.contains("work-home") ? 1400 : 956
        window.frame = CGRect(x: 0, y: 0, width: 440, height: height)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try #require(image.pngData()).write(to: url)
        #expect(host.view.bounds.width > 0)
    }
}
