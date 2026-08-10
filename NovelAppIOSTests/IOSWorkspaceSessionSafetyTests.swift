import Foundation
@testable import FUMINIWAIOS
import NovelCore
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS workspace session safety", .serialized)
struct IOSWorkspaceSessionSafetyTests {
    @Test("作品切替は古いeditor経路を新しい作品ホームへ収束させる")
    func documentChangeReplacesStaleEditorPath() {
        let firstSession = makeSession(packageName: "first.novelpkg", generation: 1)
        let secondSession = makeSession(packageName: "second.novelpkg", generation: 2)
        let navigation = IOSWorkspaceNavigationCoordinator()
        navigation.showProjectHome(for: firstSession)
        navigation.showWriting(for: firstSession)
        navigation.showEditor(
            for: firstSession,
            chapterID: ChapterID(),
            episodeID: EpisodeID()
        )

        navigation.documentDidChange(to: secondSession)

        #expect(navigation.activeSession == secondSession)
        #expect(navigation.path == [.projectHome(session: secondSession)])
    }

    @Test("同じworking copyを開き直した場合も古いnavigation sessionを置き換える")
    func reinstalledWorkingCopyReplacesOldGenerationPath() {
        let oldSession = makeSession(packageName: "work.novelpkg", generation: 1)
        let newSession = makeSession(packageName: "work.novelpkg", generation: 3)
        let navigation = IOSWorkspaceNavigationCoordinator()
        navigation.showProjectHome(for: oldSession)
        navigation.showWriting(for: oldSession)

        navigation.documentDidChange(to: newSession)

        #expect(navigation.activeSession == newSession)
        #expect(navigation.path == [.projectHome(session: newSession)])
    }

    @Test("AからBを経てAへ戻った後の古いEditor離脱は新しいAのIMEへ触れない")
    func staleEditorDepartureDoesNotTouchReinstalledSession() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let oldSession = try #require(store.currentDocumentSessionToken)
        let chapterID = try #require(store.selectedChapterID)
        let episodeID = try #require(store.selectedEpisodeID)
        #expect(await store.saveNow())

        #expect(await store.makeNewDocument())
        #expect(await store.openPrivateDocument(id: oldSession.workingCopyID))
        let newSession = try #require(store.currentDocumentSessionToken)
        #expect(newSession.workingCopyID == oldSession.workingCopyID)
        #expect(newSession != oldSession)

        let harness = try await makeEditorHarness(store: store)
        defer { harness.cleanup() }
        beginMarkedText("新しいAの変換中", in: harness.textView)
        let modelTextBeforeDeparture = store.document.episode(episodeID)?.episode.content

        let didIgnore = IOSWorkspaceEditorSynchronizer.synchronize(
            store: store,
            departure: IOSWorkspaceEditorDeparture(
                session: oldSession,
                chapterID: chapterID,
                episodeID: episodeID
            )
        )

        #expect(didIgnore)
        #expect(harness.textView.markedTextRange != nil)
        #expect(store.document.episode(episodeID)?.episode.content == modelTextBeforeDeparture)
        #expect(store.currentDocumentSessionToken == newSession)
    }

    @Test("remote install世代より古いEditor callbackを同じ話へ適用しない")
    func staleEditorCallbackDoesNotCrossRemoteInstallGeneration() async throws {
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
        let oldToken = try #require(store.currentEpisodeEditingToken)

        store.document.updateEpisodeContent("新しいremote本文", for: episodeID, in: chapterID)
        store.advanceEditorContentGeneration()
        store.updateEpisodeContent(
            "旧surfaceの遅延本文",
            chapterID: chapterID,
            episodeID: episodeID,
            expectedEditingToken: oldToken
        )

        #expect(store.document.episode(episodeID)?.episode.content == "新しいremote本文")
        #expect(store.currentEpisodeEditingToken != oldToken)
    }

    private func makeEditorHarness(store: IOSDocumentStore) async throws -> SessionEditorHarness {
        let host = UIHostingController(rootView: IOSEditorPane(store: store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()

        for _ in 0 ..< 12 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            if let textView = findTextView(in: host.view) {
                _ = textView.becomeFirstResponder()
                return SessionEditorHarness(window: window, textView: textView)
            }
            await advanceMainRunLoop()
        }

        window.isHidden = true
        window.rootViewController = nil
        Issue.record("EditorのUITextViewを取得できませんでした。")
        throw SessionEditorHarnessError.textViewNotFound
    }

    private func beginMarkedText(_ text: String, in textView: UITextView) {
        textView.selectedRange = NSRange(
            location: (textView.text as NSString).length,
            length: 0
        )
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        )
        textView.delegate?.textViewDidChange?(textView)
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

    private func makeEnvironment() -> WorkspaceSessionTestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-Workspace-Session-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.workspace-session-tests.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return WorkspaceSessionTestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
    }

    private func makeSession(
        packageName: String,
        generation: UInt64
    ) -> IOSDocumentSessionToken {
        IOSDocumentSessionToken(
            workingCopyID: IOSPrivateDocumentID(packageName: packageName),
            generation: generation
        )
    }
}

@MainActor
private struct SessionEditorHarness {
    let window: UIWindow
    let textView: UITextView

    func cleanup() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

private enum SessionEditorHarnessError: Error {
    case textViewNotFound
}

private struct WorkspaceSessionTestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
