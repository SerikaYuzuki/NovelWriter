import Foundation
@testable import FUMINIWAIOS
import NovelCore
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS workspace navigation", .serialized)
struct IOSWorkspaceNavigationTests {
    @Test("account scope park removes every stale document route")
    func accountScopeParkReturnsToLibrary() {
        let session = makeSession(packageName: "account-work.novelpkg")
        let navigation = IOSWorkspaceNavigationCoordinator()
        navigation.showProjectHome(for: session)
        navigation.showWriting(for: session)

        navigation.documentDidBecomeUnavailable()

        #expect(navigation.activeSession == nil)
        #expect(navigation.path.isEmpty)
    }

    @Test("標準Back相当のpath更新はeditorを破棄する前に同期する")
    func editorPopSynchronizesBeforePathMutation() {
        let session = makeSession(packageName: "work.novelpkg")
        let chapterID = ChapterID()
        let episodeID = EpisodeID()
        let navigation = IOSWorkspaceNavigationCoordinator()
        navigation.showProjectHome(for: session)
        navigation.showWriting(for: session)
        navigation.showEditor(
            for: session,
            chapterID: chapterID,
            episodeID: episodeID
        )
        let oldPath = navigation.path
        let proposedPath: [IOSWorkspaceRoute] = [
            .projectHome(session: session),
            .writing(session: session)
        ]
        var pathSeenDuringSynchronization: [IOSWorkspaceRoute] = []
        var receivedDeparture: IOSWorkspaceEditorDeparture?

        let didUpdate = navigation.updatePath(proposedPath) { departure in
            pathSeenDuringSynchronization = navigation.path
            receivedDeparture = departure
            return true
        }

        #expect(didUpdate)
        #expect(pathSeenDuringSynchronization == oldPath)
        #expect(
            receivedDeparture == IOSWorkspaceEditorDeparture(
                session: session,
                chapterID: chapterID,
                episodeID: episodeID
            )
        )
        #expect(navigation.path == proposedPath)
    }

    @Test("IME確定に失敗した場合はBack相当のpath更新を中止する")
    func rejectedEditorDepartureKeepsPath() {
        let session = makeSession(packageName: "work.novelpkg")
        let navigation = IOSWorkspaceNavigationCoordinator()
        navigation.showProjectHome(for: session)
        navigation.showWriting(for: session)
        navigation.showEditor(
            for: session,
            chapterID: ChapterID(),
            episodeID: EpisodeID()
        )
        let oldPath = navigation.path

        let didUpdate = navigation.updatePath(
            [.projectHome(session: session)]
        ) { _ in
            false
        }

        #expect(!didUpdate)
        #expect(navigation.path == oldPath)
    }

    @Test("iPadの執筆画面離脱は現在選択中のeditor同期を要求する")
    func writingPopRequestsAdaptiveEditorSynchronization() {
        let session = makeSession(packageName: "work.novelpkg")
        let navigation = IOSWorkspaceNavigationCoordinator()
        navigation.showProjectHome(for: session)
        navigation.showWriting(for: session)
        var receivedDeparture: IOSWorkspaceEditorDeparture?

        let didUpdate = navigation.updatePath(
            [.projectHome(session: session)]
        ) { departure in
            receivedDeparture = departure
            return true
        }

        #expect(didUpdate)
        #expect(
            receivedDeparture == IOSWorkspaceEditorDeparture(
                session: session,
                chapterID: nil,
                episodeID: nil
            )
        )
    }

    @Test("regularからcompactへ変わる前にeditor同期を完了する")
    func adaptiveLayoutSynchronizesBeforeRemovingRegularEditor() {
        var didSynchronize = false

        let nextSizeClass = IOSAdaptiveWritingLayoutTransition.nextSizeClass(
            from: .regular,
            to: .compact
        ) {
            didSynchronize = true
            return true
        }

        #expect(didSynchronize)
        #expect(nextSizeClass == .compact)
    }

    @Test("regularからcompactへの同期失敗時はeditorを残す")
    func adaptiveLayoutKeepsRegularEditorWhenSynchronizationFails() {
        let nextSizeClass = IOSAdaptiveWritingLayoutTransition.nextSizeClass(
            from: .regular,
            to: .compact
        ) {
            false
        }

        #expect(nextSizeClass == .regular)
    }

    @Test("離脱同期は実UITextViewのIMEを確定して最新全文をmodelへ反映する")
    func editorDepartureCommitsIMEAndCapturesLatestText() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let chapterID = try #require(store.selectedChapterID)
        let episodeID = try #require(store.selectedEpisodeID)
        let session = try #require(store.currentDocumentSessionToken)

        let host = UIHostingController(rootView: IOSEditorPane(store: store, userDefaults: store.userDefaults))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        for _ in 0 ..< 8 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await advanceMainRunLoop()
        }
        let textView = try #require(findTextView(in: host.view))
        _ = textView.becomeFirstResponder()
        let markedText = "変換中"
        beginMarkedText(markedText, in: textView)

        #expect(textView.markedTextRange != nil)
        #expect(store.document.episode(episodeID)?.episode.content != textView.text)

        let didSynchronize = IOSWorkspaceEditorSynchronizer.synchronize(
            store: store,
            departure: IOSWorkspaceEditorDeparture(
                session: session,
                chapterID: chapterID,
                episodeID: episodeID
            )
        )

        #expect(didSynchronize)
        #expect(textView.markedTextRange == nil)
        #expect(store.document.episode(episodeID)?.episode.content == textView.text)
        #expect(textView.text.hasSuffix(markedText))
    }

    @Test("iPadの話切替は旧話のIME確定全文を反映してから選択を変える")
    func writingIdentityBoundarySynchronizesBeforeEpisodeSelection() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let chapterID = try #require(store.selectedChapterID)
        let firstEpisodeID = try #require(store.selectedEpisodeID)
        store.addEpisode()
        let secondEpisodeID = try #require(store.selectedEpisodeID)
        store.selectChapter(chapterID)
        store.selectEpisode(firstEpisodeID)

        let host = UIHostingController(rootView: IOSEditorPane(store: store, userDefaults: store.userDefaults))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        for _ in 0 ..< 8 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await advanceMainRunLoop()
        }
        let textView = try #require(findTextView(in: host.view))
        _ = textView.becomeFirstResponder()
        let markedText = "切替直前"
        beginMarkedText(markedText, in: textView)
        #expect(textView.markedTextRange != nil)
        #expect(store.document.episode(firstEpisodeID)?.episode.content != textView.text)

        let didChangeSelection = IOSWritingEditorIdentityBoundary(store: store).perform {
            store.selectChapter(chapterID)
            store.selectEpisode(secondEpisodeID)
        }

        #expect(didChangeSelection)
        #expect(textView.markedTextRange == nil)
        #expect(store.document.episode(firstEpisodeID)?.episode.content.hasSuffix(markedText) == true)
        #expect(store.selectedEpisodeID == secondEpisodeID)
    }

    private func beginMarkedText(_ markedText: String, in textView: UITextView) {
        textView.selectedRange = NSRange(
            location: (textView.text as NSString).length,
            length: 0
        )
        textView.setMarkedText(
            markedText,
            selectedRange: NSRange(location: (markedText as NSString).length, length: 0)
        )
        textView.delegate?.textViewDidChange?(textView)
    }

    private func makeSession(
        packageName: String,
        generation: UInt64 = 1
    ) -> IOSDocumentSessionToken {
        IOSDocumentSessionToken(
            workingCopyID: IOSPrivateDocumentID(packageName: packageName),
            generation: generation
        )
    }

    private func makeEnvironment() -> WorkspaceTestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-Workspace-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.workspace-tests.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return WorkspaceTestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
    }

    private func advanceMainRunLoop() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                continuation.resume()
            }
        }
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }
}

private struct WorkspaceTestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
