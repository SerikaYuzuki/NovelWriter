import Foundation
@testable import FUMINIWAIOS
import NovelSyncV2Application
import SwiftUI
import Testing
import UIKit

@Suite("iPad workbench sidebar layout", .serialized)
@MainActor
struct IOSWorkbenchSidebarLayoutTests {
    @Test("regular layout keeps the project list mounted through outline and detail-only sections")
    func sidebarSurvivesSectionSwitches() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url,
                                     runtimeComposition: .test(configuration))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let host = UIHostingController(rootView: IOSAdaptiveWritingView(store: store, openEpisode: { _, _ in })
            .environment(\.horizontalSizeClass, .regular))
        host.traitOverrides.horizontalSizeClass = .regular
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        host.view.layoutIfNeeded()
        let split = try #require(controllers(host).compactMap { $0 as? UISplitViewController }.first)
        split.preferredDisplayMode = .oneBesideSecondary
        split.show(.primary)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!split.isCollapsed)
        let primary = try #require(split.viewController(for: .primary))
        let list = try #require(views(primary.view).compactMap { $0 as? UICollectionView }.first)
        let origin = list.contentOffset
        let selections = [IndexPath(item: 0, section: 1), IndexPath(item: 1, section: 0),
                          IndexPath(item: 0, section: 0), IndexPath(item: 2, section: 0),
                          IndexPath(item: 0, section: 1), IndexPath(item: 1, section: 0)]
        for index in selections {
            list.selectItem(at: index, animated: false, scrollPosition: [])
            list.delegate?.collectionView?(list, didSelectItemAt: index)
            try await Task.sleep(for: .milliseconds(400))
            let splits = controllers(host).compactMap { $0 as? UISplitViewController }
            #expect(index.section == 1 || index.item == 0 ? splits.count == 1 : splits.count >= 2)
            #expect(primary.view.window != nil)
            let current = try #require(split.viewController(for: .primary))
            #expect(ObjectIdentifier(current) == ObjectIdentifier(primary))
            #expect(views(current.view).contains { $0 === list })
            #expect(abs(list.contentOffset.y - origin.y) < 1)
            #expect(list.indexPathsForVisibleItems.contains(IndexPath(item: 0, section: 0)))
        }
    }

    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap { controllers($0) }
    }

    private func views(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views($0) }
    }
}
