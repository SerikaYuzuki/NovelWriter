import Foundation
@testable import FUMINIWAIOS
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS attachment editor safety", .serialized)
struct IOSAttachmentEditorSafetyTests {
    @Test("実UITextViewがIME変換中なら資料取込と原稿変更を拒否する")
    func importRejectsActiveCompositionWithoutChangingDocument() async throws {
        let environment = makeEnvironment(prefix: "attachment-ime")
        defer { environment.cleanup() }
        let sourceURL = try makeSourceFile(in: environment.root, contents: "reference")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)
        let episodeID = try #require(store.selectedEpisodeID)
        let originalContent = try #require(store.document.episode(episodeID)?.episode.content)
        let harness = try await makeEditorHarness(store: store)
        defer { harness.cleanup() }

        beginMarkedText("変換中", in: harness.textView)
        let composingText = harness.textView.text
        #expect(harness.textView.markedTextRange != nil)

        let attachment = await store.importAttachment(
            from: sourceURL,
            expectedSession: session
        )

        #expect(attachment == nil)
        #expect(store.attachments.isEmpty)
        #expect(store.document.episode(episodeID)?.episode.content == originalContent)
        #expect(harness.textView.text == composingText)
        #expect(harness.textView.markedTextRange != nil)
        #expect(store.operationErrorMessage == "日本語入力を確定してから、もう一度お試しください。")
    }

    @Test("実UITextViewの確定済み最新全文を保存してから資料を取り込む")
    func importCapturesLatestCommittedEditorTextBeforeSaving() async throws {
        let environment = makeEnvironment(prefix: "attachment-capture")
        defer { environment.cleanup() }
        let sourceURL = try makeSourceFile(in: environment.root, contents: "reference")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)
        let episodeID = try #require(store.selectedEpisodeID)
        let harness = try await makeEditorHarness(store: store)
        defer { harness.cleanup() }
        let latestText = "UITextViewだけが持つ確定済みの最新本文"
        harness.textView.text = latestText
        #expect(store.document.episode(episodeID)?.episode.content != latestText)

        let attachment = try #require(
            await store.importAttachment(from: sourceURL, expectedSession: session)
        )

        #expect(store.attachments == [attachment])
        #expect(store.document.episode(episodeID)?.episode.content == latestText)

        let reopened = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopened.bootstrap()
        #expect(reopened.document.episode(episodeID)?.episode.content == latestText)
        #expect(reopened.attachments == [attachment])
    }

    @Test("実UITextViewがIME変換中なら資料削除と原稿変更を拒否する")
    func deleteRejectsActiveCompositionWithoutChangingDocument() async throws {
        let environment = makeEnvironment(prefix: "attachment-delete-ime")
        defer { environment.cleanup() }
        let sourceURL = try makeSourceFile(in: environment.root, contents: "reference")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)
        let episodeID = try #require(store.selectedEpisodeID)
        let attachment = try #require(
            await store.importAttachment(from: sourceURL, expectedSession: session)
        )
        let attachmentURL = try #require(
            store.attachmentPreviewURL(for: attachment, expectedSession: session)
        )
        let originalContent = try #require(store.document.episode(episodeID)?.episode.content)
        let harness = try await makeEditorHarness(store: store)
        defer { harness.cleanup() }

        beginMarkedText("削除前の変換中", in: harness.textView)
        let composingText = harness.textView.text
        #expect(harness.textView.markedTextRange != nil)

        #expect(await !(store.deleteAttachment(attachment, expectedSession: session)))
        #expect(store.attachments == [attachment])
        #expect(FileManager.default.fileExists(atPath: attachmentURL.path))
        #expect(store.document.episode(episodeID)?.episode.content == originalContent)
        #expect(harness.textView.text == composingText)
        #expect(harness.textView.markedTextRange != nil)
        #expect(store.operationErrorMessage == "日本語入力を確定してから、もう一度お試しください。")
    }

    private func makeEditorHarness(store: IOSDocumentStore) async throws -> EditorHarness {
        let host = UIHostingController(rootView: IOSEditorPane(store: store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()

        for _ in 0 ..< 12 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await advanceMainRunLoop()
            if let textView = findTextView(in: host.view) {
                _ = textView.becomeFirstResponder()
                return EditorHarness(window: window, textView: textView)
            }
        }

        window.isHidden = true
        window.rootViewController = nil
        Issue.record("EditorのUITextViewを取得できませんでした。")
        throw AttachmentEditorHarnessError.textViewNotFound
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

    private func makeSourceFile(in root: URL, contents: String) throws -> URL {
        let sourceURL = root
            .deletingLastPathComponent()
            .appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: sourceURL)
        return sourceURL
    }

    private func makeEnvironment(prefix: String) -> AttachmentEditorTestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-\(prefix)-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.\(prefix)-tests.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AttachmentEditorTestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
    }
}

@MainActor
private struct EditorHarness {
    let window: UIWindow
    let textView: UITextView

    func cleanup() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

private enum AttachmentEditorHarnessError: Error {
    case textViewNotFound
}

private struct AttachmentEditorTestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
