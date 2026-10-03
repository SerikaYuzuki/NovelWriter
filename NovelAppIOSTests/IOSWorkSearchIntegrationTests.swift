import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelTextAnalysis
import Observation
import SwiftUI
import Testing
import UIKit

@MainActor
struct IOSWorkSearchIntegrationTests {
    @Test func pushedEditorLeavesSearchStaleUntilReturn() async throws {
        let defaults = try #require(UserDefaults(suiteName: "IOSWorkSearchVisibility.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let chapter = try #require(store.selectedChapterID), episode = try #require(store.selectedEpisodeID)
        store.document.updateEpisodeContent("猫猫", for: episode, in: chapter)
        store.markDocumentChanged()
        #expect(await store.saveNow())
        store.workSearch.query = "猫"
        let probe = SearchVisibilityProbe()
        let controller = UIHostingController(rootView: SearchVisibilityHost(store: store, probe: probe))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForWorkSearchState { !store.workSearch.isStale }
        #expect(store.workSearch.total == 2)
        #expect(!store.workSearch.isStale)
        probe.path = [true]
        try await waitForWorkSearchState {
            store.workSearch.isStale && store.editorCommandSession.captureActiveCommittedText() == .captured("猫猫")
        }
        #expect(store.editorCommandSession.hasActiveEditorSurface)
        for index in 1 ... 5 {
            let content = String(repeating: "猫", count: 2 + index)
            #expect(store.editorCommandSession.applyProofreading(
                expectedText: String(repeating: "猫", count: 1 + index), replacement: content
            ))
            try await waitForWorkSearchState {
                store.document.episode(episode)?.episode.content == content
            }
            #expect(store.workSearch.total == 2)
            #expect(store.workSearch.isStale)
            #expect(!store.workSearch.isSearching)
        }
        probe.path = []
        try await waitForWorkSearchState { !store.workSearch.isStale }
        #expect(store.workSearch.total == 7)
        #expect(!store.workSearch.isStale)
        #expect(await store.saveNow())
    }

    @Test func editorReplacementUndoNoProgressOrAIAndScopedJump() async throws {
        let defaults = try #require(UserDefaults(suiteName: "IOSWorkSearchTests.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let work = try #require(store.syncV2ActiveWorkID), chapter = try #require(store.selectedChapterID),
            episode = try #require(store.selectedEpisodeID)
        store.document.updateEpisodeContent("猫猫", for: episode, in: chapter)
        store.document.chapters[0].episodes.append(Episode(title: "第2話", content: "猫"))
        store.markDocumentChanged()
        #expect(await store.saveNow())
        let editor = UIHostingController(rootView: IOSEditorPane(store: store, userDefaults: defaults))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = editor; editor.view.frame = window.bounds; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(250))
        editor.view.layoutIfNeeded()
        #expect(store.editorCommandSession.hasActiveEditorSurface)
        let generation = store.editorContentGeneration
        let search = store.workSearch
        search.query = "猫"; search.replacement = "子猫"
        search.refresh(document: store.document, scope: store.workSearchScope)
        try await Task.sleep(for: .milliseconds(450))
        #expect(await search.replace(using: store.workReplacementHost))
        #expect(store.editorContentGeneration == generation)
        #expect(store.editorCommandSession.captureActiveCommittedText() == .captured("子猫子猫"))
        #expect(store.document.chapters[0].episodes.map { $0.content } == ["子猫子猫", "子猫"])
        #expect(store.writingProgress.days(for: work.rawValue).isEmpty)
        #expect(store.writingProgress.total == 6)
        let writing = try #require(store.writingAssistantHost)
        #expect(try await writing.records(false).isEmpty)
        #expect(await search.undo(using: store.workReplacementHost))
        #expect(store.editorCommandSession.captureActiveCommittedText() == .captured("猫猫"))
        #expect(store.writingProgress.days(for: work.rawValue).isEmpty)
        #expect(try await writing.records(false).isEmpty)
        if case let .test(configuration) = store.runtimeComposition {
            #expect(try workSearchJournalCount(root: configuration.localRoot.url) == 0)
        }
        let application = try #require(store.snapshotSyncV2Application)
        #expect(try await application.historyPage(workID: work).items.contains { $0.reason == "explicit" })
        #expect(try await application.openLocal(workID: work).document == store.document)
        search.refresh(document: store.document, scope: store.workSearchScope)
        try await Task.sleep(for: .milliseconds(450))
        let beforeFailure = store.document, originalHost = store.workReplacementHost
        let failingSnapshot = WorkReplacementHost(scope: originalHost.scope, validate: originalHost.validate,
                                                  document: originalHost.document, boundary: originalHost.boundary,
                                                  snapshot: { false }, apply: originalHost.apply)
        #expect(await !(search.replace(using: failingSnapshot)))
        #expect(store.document == beforeFailure)
        let accountHost = store.workReplacementHost
        store.syncSessionController.accountGeneration &+= 1
        #expect(!accountHost.validate())
        let host = store.workReplacementHost
        store.advanceDocumentSessionGeneration()
        #expect(!host.validate())
        let scope = store.workSearchScope
        let target = store.document.chapters[0].episodes[1]
        #expect(await store.selectWorkTextMatch(chapterID: chapter, episodeID: target.id, source: target.content,
                                                range: NSRange(location: 0, length: 1), expectedScope: scope))
        #expect(store.currentWorkTextSelectionRequest?.range == NSRange(location: 0, length: 1))
        store.advanceDocumentSessionGeneration()
        #expect(store.currentWorkTextSelectionRequest == nil)
        #expect(await !(store.selectWorkTextMatch(chapterID: chapter, episodeID: target.id, source: target.content,
                                                  range: NSRange(location: 0, length: 1), expectedScope: scope)))
    }
}

@MainActor @Observable
private final class SearchVisibilityProbe {
    var path: [Bool] = []
}

private struct SearchVisibilityHost: View {
    let store: IOSDocumentStore
    @Bindable var probe: SearchVisibilityProbe
    var body: some View {
        NavigationStack(path: $probe.path) {
            IOSWorkSearchView(store: store)
                .navigationDestination(for: Bool.self) { _ in
                    IOSEditorPane(store: store, userDefaults: store.userDefaults)
                }
        }
    }
}
