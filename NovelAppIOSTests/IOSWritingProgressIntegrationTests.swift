import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWritingSupport
import SwiftUI
import Testing
import UIKit

@MainActor
struct IOSWritingProgressIntegrationTests {
    @Test func manualInputSkipsAllEpisodeSynchronization() async throws {
        let defaults = try #require(UserDefaults(suiteName: "IOSWritingProgressTests.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let chapter = try #require(store.workspaceModel.selectedChapterID), episode = try #require(store.workspaceModel.selectedEpisodeID)
        store.workspaceModel.document.chapters[0].episodes.append(Episode(title: "別の話", content: "別"))
        store.markDocumentChanged()
        let other = store.workspaceModel.document.chapters[0].episodes[1].id
        // A changed, unreported second episode is a sentinel for an all-episode scan.
        store.workspaceModel.document.updateEpisodeContent("別の変更", for: other, in: chapter)
        store.updateEpisodeContent("文", chapterID: chapter, episodeID: episode)
        #expect(store.writingProgress.episodeCount(other) == 1)
        #expect(store.writingProgress.total == 1)
        store.writingProgress.publishSnapshot()
        #expect(store.writingProgress.total == 2)
        store.markDocumentChanged()
        #expect(store.writingProgress.episodeCount(other) == 4)
        #expect(store.writingProgress.total == 5)
        #expect(await store.saveNow())
    }

    @Test func guardedManualEntryAndInstallExcludeOtherSources() async throws {
        let defaults = try #require(UserDefaults(suiteName: "IOSWritingProgressTests.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let work = try #require(store.workspaceModel.activeWorkID)
        let chapter = try #require(store.workspaceModel.selectedChapterID), episode = try #require(store.workspaceModel.selectedEpisodeID)
        let token = try #require(store.currentEpisodeEditingToken)
        store.updateEpisodeContent("三文字", chapterID: chapter, episodeID: episode, expectedEditingToken: token)
        store.updateEpisodeContent("三文字", chapterID: chapter, episodeID: episode)
        store.advanceEditorContentGeneration()
        store.updateEpisodeContent("古い入力", chapterID: chapter, episodeID: episode, expectedEditingToken: token)
        store.writingProgress.publishSnapshot()
        #expect(store.writingProgress.days(for: work.rawValue).values.first?.added == 3)
        store.workspaceModel.document.updateEpisodeContent(String(repeating: "文", count: 10000), for: episode, in: chapter)
        store.markDocumentChanged()
        store.writingProgress.publishSnapshot()
        #expect(store.writingProgress.days(for: work.rawValue).values.first?.added == 3)
        #expect(store.writingProgress.notice == nil)
        #expect(store.writingProgress.milestones(for: work.rawValue).first?.reachedAt == nil)
        // Reinstalling the same work keeps its stored creation time, the checkpoint anchor.
        #expect(store.install(store.workspaceModel.document, at: root, attachments: [], workID: work,
                              createdAt: store.documentCreatedAt))
        #expect(store.writingProgress.days(for: work.rawValue).values.first?.added == 3)
        #expect(await store.saveNow())
    }

    @Test(arguments: [false, true])
    func remoteReplacementThenManualCharacter(notifyInstall: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "IOSWritingProgressTests.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let work = try #require(store.workspaceModel.activeWorkID)
        let chapter = try #require(store.workspaceModel.selectedChapterID), episode = try #require(store.workspaceModel.selectedEpisodeID)
        var document = store.workspaceModel.document
        let remoteContent = String(repeating: "文", count: 10000)
        document.updateEpisodeContent(remoteContent, for: episode, in: chapter)
        if notifyInstall {
            let opened = SyncV2OpenedWork(
                workID: work, document: document, documentCreatedAt: store.documentCreatedAt,
                generation: 1, snapshotID: nil
            )
            #expect(store.installSnapshotSyncV2Opened(opened, value: document, preservingSelection: true))
            store.writingProgress.publishSnapshot()
            #expect(store.writingProgress.total == 10000)
            #expect(store.workspaceModel.selectedChapterID == chapter)
            #expect(store.workspaceModel.selectedEpisodeID == episode)
            #expect(store.writingProgress.days(for: work.rawValue).isEmpty)
        } else {
            store.workspaceModel.document = document
            store.workspaceModel.documentSessionToken.documentID = store.workspaceModel.document.id
        }
        #expect(store.writingProgress.notice == nil)
        let token = try #require(store.currentEpisodeEditingToken)
        store.updateEpisodeContent(remoteContent + "一", chapterID: chapter, episodeID: episode, expectedEditingToken: token)
        store.writingProgress.publishSnapshot()
        #expect(store.writingProgress.days(for: work.rawValue).values.first?.added == 1)
        #expect(store.writingProgress.days(for: work.rawValue).values.first?.net == 1)
        #expect(store.writingProgress.total == 10001)
        #expect(store.writingProgress.milestones(for: work.rawValue).first?.reachedAt == nil)
        #expect(store.writingProgress.notice == nil)
        #expect(await store.saveNow())
    }

    @Test func actualAIEditAndUndoDoNotCount() async throws {
        let defaults = try #require(UserDefaults(suiteName: "IOSWritingProgressTests.\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let work = try #require(store.workspaceModel.activeWorkID), chapter = try #require(store.workspaceModel.selectedChapterID),
            episode = try #require(store.workspaceModel.selectedEpisodeID)
        let path = [
            "chapters",
            chapter.rawValue.uuidString.lowercased(),
            "episodes",
            episode.rawValue.uuidString.lowercased(),
            "content"
        ]
        let edit = WritingEdit(
            workId: work.rawValue,
            documentId: store.workspaceModel.document.id,
            changes: [WritingChange(
                path: path,
                before: .string(""),
                after: .string(String(repeating: "文", count: 10000))
            )]
        )
        let editorHost = UIHostingController(rootView: IOSEditorPane(store: store, userDefaults: defaults).environment(store.workspaceModel))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = editorHost
        editorHost.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(200))
        editorHost.view.layoutIfNeeded()
        #expect(store.editorCommandSession.hasActiveEditorSurface)
        let host = try #require(store.writingAssistantHost)
        try await host.apply(edit, WritingGrant(paths: [path]))
        store.writingProgress.publishSnapshot()
        #expect(store.writingProgress.total == 10000)
        #expect(store.writingProgress.days(for: work.rawValue).isEmpty)
        #expect(store.writingProgress.notice == nil)
        try await host.undo(edit.id)
        store.writingProgress.publishSnapshot()
        #expect(store.writingProgress.total == 0)
        #expect(store.writingProgress.days(for: work.rawValue).isEmpty)
        store.updateEpisodeContent("手入力", chapterID: chapter, episodeID: episode)
        store.writingProgress.publishSnapshot()
        #expect(store.writingProgress.days(for: work.rawValue).values.first?.added == 3)
        #expect(await store.saveNow())
    }
}
