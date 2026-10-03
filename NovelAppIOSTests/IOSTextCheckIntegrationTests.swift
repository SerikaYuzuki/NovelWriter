import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelTextAnalysis
import SwiftUI
import Testing
import UIKit

@MainActor
struct IOSTextCheckIntegrationTests {
    @Test func resultJumpAndReplacementPrefillPreserveManuscript() async throws {
        let defaults = try #require(UserDefaults(suiteName: "IOSTextCheckTests.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let chapter = try #require(store.selectedChapterID)
        store.document.chapters[0].episodes[0].content = "　出来る。出来る。"
        store.document.chapters[0].episodes.append(Episode(title: "二", content: "　できる。…"))
        store.markDocumentChanged()
        #expect(await store.saveNow())
        let document = store.document
        await store.runTextCheck()
        let variation = try #require(store.textCheck.results.first { $0.rule == .dictionaryVariation })
        let occurrence = try #require(variation.occurrences.last)
        let scope = store.workSearchScope
        #expect(await store.selectWorkTextMatch(chapterID: chapter, episodeID: occurrence.result.id,
                                                source: occurrence.result.source, range: occurrence.match.range, expectedScope: scope))
        #expect(store.selectedEpisodeID == occurrence.result.id)
        #expect(store.currentWorkTextSelectionRequest?.range == occurrence.match.range)
        let editorHost = UIHostingController(rootView: IOSEditorPane(store: store, userDefaults: defaults))
        let editorWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        editorWindow.rootViewController = editorHost; editorWindow.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        editorHost.view.layoutIfNeeded()
        let textView = try #require(findTextView(editorHost.view))
        #expect(textView.selectedRange == occurrence.match.range)
        editorWindow.isHidden = true; editorWindow.rootViewController = nil
        #expect(store.prepareTextCheckReplacement(variation))
        #expect(store.workSearch.query == "できる")
        #expect(store.workSearch.replacement == "出来る")
        #expect(store.document == document)
        let host = UIHostingController(rootView: NavigationStack { IOSTextCheckView(store: store).environment(\.dynamicTypeSize, .large) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width > 0)
        if let capture = ProcessInfo.processInfo.environment["FUMINIWA_TEXTCHECK_CAPTURE"] {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: capture))
            host.rootView = NavigationStack { IOSTextCheckView(store: store).environment(\.dynamicTypeSize, .accessibility3) }
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            let large = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try large.pngData()?.write(to: URL(fileURLWithPath: capture + ".ax.png"))
        }
        store.syncSessionController.accountGeneration &+= 1
        #expect(!store.prepareTextCheckReplacement(variation))
        #expect(await !(store.selectWorkTextMatch(chapterID: chapter, episodeID: occurrence.result.id,
                                                  source: occurrence.result.source, range: occurrence.match.range, expectedScope: scope)))
    }

    private func findTextView(_ view: UIView) -> UITextView? {
        if let text = view as? UITextView {
            return text
        }
        return view.subviews.lazy.compactMap { findTextView($0) }.first
    }
}
