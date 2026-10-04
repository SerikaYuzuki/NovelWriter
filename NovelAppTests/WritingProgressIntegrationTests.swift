import AppKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelWritingSupport
import SwiftUI
import Testing

@MainActor
struct WritingProgressIntegrationTests {
    @Test func manualInputSkipsAllEpisodeSynchronization() {
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()),
                             initialStartupState: .ready)
        var document = NovelDocument.newDocument()
        document.chapters[0].episodes.append(Episode(title: "別の話", content: "別"))
        let work = WorkID(UUID()), chapter = document.chapters[0].id, episode = document.chapters[0].episodes[0].id
        let other = document.chapters[0].episodes[1].id
        #expect(state.installV2Document(document, workID: work, createdAt: Date()))
        // A changed, unreported second episode is a sentinel for an all-episode scan.
        state.workspaceModel.document.updateEpisodeContent("別の変更", for: other, in: chapter)
        state.updateEpisodeContent("文", for: episode, in: chapter)
        #expect(state.writingProgress.episodeCount(other) == 1)
        #expect(state.writingProgress.total == 1) // Published snapshot is still the installed total.
        state.writingProgress.publishSnapshot()
        #expect(state.writingProgress.total == 2)
        state.markDocumentDirty()
        #expect(state.writingProgress.episodeCount(other) == 4)
        #expect(state.writingProgress.total == 5)
    }

    @Test func guardedManualEntryAndExcludedMutations() {
        let state = AppState(
            dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()),
            initialStartupState: .ready
        )
        let doc = NovelDocument.newDocument(), work = WorkID(UUID())
        #expect(state.installV2Document(doc, workID: work, createdAt: Date()))
        let chapter = doc.chapters[0].id, episode = doc.chapters[0].episodes[0].id
        let session = state.workspaceModel.documentSessionToken, generation = state.workspaceModel.editorContentGeneration
        state.updateEpisodeContent(
            "三文字",
            for: episode,
            in: chapter,
            expectedSession: session,
            expectedEditorContentGeneration: generation
        )
        state.updateEpisodeContent("三文字", for: episode, in: chapter) // unchanged
        state.updateEpisodeContent(
            "拒否される入力",
            for: episode,
            in: chapter,
            expectedEditorContentGeneration: generation &+ 1
        )
        state.writingProgress.publishSnapshot()
        #expect(state.writingProgress.days(for: work.rawValue).values.first?.added == 3)
        state.workspaceModel.document.updateEpisodeContent(String(repeating: "文", count: 10000), for: episode, in: chapter)
        state.markDocumentDirty() // AI/MCP path
        state.writingProgress.publishSnapshot()
        #expect(state.writingProgress.days(for: work.rawValue).values.first?.added == 3)
        #expect(state.writingProgress.milestones(for: work.rawValue).first?.reachedAt == nil)
        #expect(state.writingProgress.notice == nil)
        #expect(state.installV2Document(state.workspaceModel.document, workID: work, createdAt: Date()))
        state.updateEpisodeContent("古いsession", for: episode, in: chapter, expectedSession: session)
        state.writingProgress.publishSnapshot()
        #expect(state.writingProgress.days(for: work.rawValue).values.first?.added == 3)
        let other = WorkID(UUID())
        #expect(state.installV2Document(state.workspaceModel.document, workID: other, createdAt: Date()))
        state.writingProgress.publishSnapshot()
        #expect(state.writingProgress.days(for: other.rawValue).isEmpty)
    }

    @Test(arguments: [false, true])
    func remoteReplacementThenManualCharacter(notifyInstall: Bool) {
        let state = AppState(
            dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()),
            initialStartupState: .ready
        )
        var document = NovelDocument.newDocument()
        let work = WorkID(UUID()), chapter = document.chapters[0].id, episode = document.chapters[0].episodes[0].id
        #expect(state.installV2Document(document, workID: work, createdAt: Date()))
        let remoteContent = String(repeating: "文", count: 10000)
        document.updateEpisodeContent(remoteContent, for: episode, in: chapter)
        if notifyInstall {
            #expect(state.installV2Document(document, workID: work, createdAt: Date()))
            state.writingProgress.publishSnapshot()
            #expect(state.writingProgress.total == 10000)
        } else {
            state.workspaceModel.document = document
        }
        #expect(state.writingProgress.notice == nil)
        state.updateEpisodeContent(remoteContent + "一", for: episode, in: chapter)
        state.writingProgress.publishSnapshot()
        #expect(state.writingProgress.days(for: work.rawValue).values.first?.added == 1)
        #expect(state.writingProgress.days(for: work.rawValue).values.first?.net == 1)
        #expect(state.writingProgress.total == 10001)
        #expect(state.writingProgress.milestones(for: work.rawValue).first?.reachedAt == nil)
        #expect(state.writingProgress.notice == nil)
    }

    @Test func actualWritingEditAndPersistentUndoAreExcluded() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(
            dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()),
            initialStartupState: .ready
        )
        state.snapshotSyncV2Application = application
        let doc = NovelDocument.newDocument(), work = WorkID(UUID())
        #expect(state.installV2Document(doc, workID: work, createdAt: Date()))
        #expect(await state.checkpointSnapshotSyncV2(doc))
        let chapter = doc.chapters[0].id, episode = doc.chapters[0].episodes[0].id
        let path = [
            "chapters",
            chapter.rawValue.uuidString.lowercased(),
            "episodes",
            episode.rawValue.uuidString.lowercased(),
            "content"
        ]
        let edit = WritingEdit(
            workId: work.rawValue,
            documentId: doc.id,
            changes: [WritingChange(
                path: path,
                before: .string(""),
                after: .string(String(repeating: "文", count: 10000))
            )]
        )
        let window = try await makeActiveEditorWindow(state: state)
        defer { window.close() }
        let host = try #require(state.writingAssistantHost)
        try await host.apply(edit, WritingGrant(paths: [path]))
        state.writingProgress.publishSnapshot()
        #expect(state.writingProgress.total == 10000)
        #expect(state.writingProgress.days(for: work.rawValue).isEmpty)
        #expect(state.writingProgress.notice == nil)
        try await host.undo(edit.id)
        state.writingProgress.publishSnapshot()
        #expect(state.writingProgress.total == 0)
        #expect(state.writingProgress.days(for: work.rawValue).isEmpty)
        state.updateEpisodeContent("手入力", for: episode, in: chapter)
        state.writingProgress.publishSnapshot()
        #expect(state.writingProgress.days(for: work.rawValue).values.first?.added == 3)
    }

    private func makeActiveEditorWindow(state: AppState) async throws -> NSWindow {
        let editorHost = NSHostingView(rootView: EditorPaneView()
            .environment(state).environment(state.workspaceModel)
            .environment(EditorSettings(userDefaults: makeIsolatedTestUserDefaults(), appearanceApplier: { _ in }))
            .environment(EditorSearchSession())
            .environment(state.editorCommandSession))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = editorHost
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        editorHost.layoutSubtreeIfNeeded()
        #expect(state.editorCommandSession.hasActiveEditorSurface)
        return window
    }
}
