import AppKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelTextAnalysis
import SwiftUI
import Testing

@MainActor
struct WorkSearchIntegrationTests {
    @Test func nativeEditorReplacementUndoCheckpointAndNoAIRecordsOrProgress() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(
            dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()),
            initialStartupState: .ready
        )
        state.snapshotSyncV2Application = application
        var document = NovelDocument.newDocument()
        document.chapters = [Chapter(
            title: "第1章",
            episodes: [Episode(title: "第1話", content: "猫猫"), Episode(title: "第2話", content: "猫")]
        )]
        let work = WorkID(UUID())
        #expect(state.installV2Document(document, workID: work, createdAt: Date()))
        #expect(await state.checkpointSnapshotSyncV2(document))
        let window = try await makeEditorWindow(state: state)
        defer { window.close() }
        let hostView = try #require(window.contentView)
        let textView = try #require(findTextView(in: hostView))
        let undo = try #require(textView.undoManager)
        undo.groupsByEvent = false
        let generation = state.workspaceModel.editorContentGeneration
        let search = state.workSearch
        search.query = "猫"; search.replacement = "子猫"
        search.refresh(document: state.workspaceModel.document, scope: state.workSearchScope)
        try await Task.sleep(for: .milliseconds(450))
        undo.beginUndoGrouping()
        #expect(await search.replace(using: state.workReplacementHost))
        undo.endUndoGrouping()
        #expect(state.workspaceModel.editorContentGeneration == generation)
        #expect(state.workspaceModel.document.chapters[0].episodes.map { $0.content } == ["子猫子猫", "子猫"])
        #expect(state.editorCommandSession.captureActiveCommittedText() == .captured("子猫子猫"))
        #expect(state.writingProgress.days(for: work.rawValue).isEmpty)
        #expect(state.writingProgress.total == 6)
        let writing = try #require(state.writingAssistantHost)
        #expect(try await writing.records(false).isEmpty)
        let history = try await application.historyPage(workID: work)
        #expect(history.items.contains { $0.reason == "explicit" })
        #expect(try await application.openLocal(workID: work).document == state.workspaceModel.document)
        #expect(try workSearchJournalCount(root: configuration.localRoot.url) == 0)
        state.writingProgress.withUncountedEditorChange { undo.undo(); return true }
        #expect(textView.string == "猫猫")
        state.writingProgress.withUncountedEditorChange { undo.redo(); return true }
        #expect(textView.string == "子猫子猫")
        undo.beginUndoGrouping()
        #expect(await search.undo(using: state.workReplacementHost))
        undo.endUndoGrouping()
        #expect(state.editorCommandSession.captureActiveCommittedText() == .captured("猫猫"))
        #expect(state.workspaceModel.document.chapters[0].episodes.map { $0.content } == ["猫猫", "猫"])
        #expect(state.writingProgress.days(for: work.rawValue).isEmpty)
        // Native Undo exists independently of the one-shot work-level undo.
        #expect(textView.undoManager?.canUndo == true)
        #expect(try await writing.records(false).isEmpty)
        #expect(try workSearchJournalCount(root: configuration.localRoot.url) == 0)
        let accountHost = state.workReplacementHost
        state.snapshotSyncV2AccountScopeGeneration &+= 1
        #expect(!accountHost.validate())
        let oldHost = state.workReplacementHost
        #expect(state.installV2Document(state.workspaceModel.document, workID: WorkID(UUID()), createdAt: Date()))
        #expect(!oldHost.validate())
    }

    @Test func explicitSnapshotFailureLeavesAllEpisodesUntouched() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        var dependencies = AppDependencies(userDefaults: makeIsolatedTestUserDefaults())
        dependencies.snapshotSyncV2CheckpointOverride = { app, work, doc, reason, date, attachments, resources in
            if reason == .explicit {
                throw CocoaError(.fileWriteUnknown)
            }
            return try await app.checkpoint(
                workID: work,
                document: doc,
                reason: reason,
                documentCreatedAt: date,
                attachments: attachments,
                resources: resources
            )
        }
        let state = AppState(dependencies: dependencies, initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        var document = NovelDocument.newDocument(); document.chapters[0].episodes[0].content = "猫"
        #expect(state.installV2Document(document, workID: WorkID(UUID()), createdAt: Date()))
        #expect(await state.checkpointSnapshotSyncV2(document))
        state.workSearch.query = "猫"; state.workSearch.replacement = "犬"
        state.workSearch.refresh(document: document, scope: state.workSearchScope)
        try await Task.sleep(for: .milliseconds(450))
        #expect(await !(state.workSearch.replace(using: state.workReplacementHost)))
        #expect(state.workspaceModel.document == document)
        #expect(!state.workSearch.canUndo)
    }

    @Test func markedTextIsCommittedAndStaleSearchDoesNotReplace() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(
            dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()),
            initialStartupState: .ready
        )
        state.snapshotSyncV2Application = application
        var document = NovelDocument.newDocument()
        document.chapters[0].episodes[0].content = "猫"
        let work = WorkID(UUID())
        #expect(state.installV2Document(document, workID: work, createdAt: Date()))
        #expect(await state.checkpointSnapshotSyncV2(document))
        let window = try await makeEditorWindow(state: state)
        defer { window.close() }
        let contentView = try #require(window.contentView)
        let editor = try #require(findTextView(in: contentView))
        let search = state.workSearch
        search.query = "猫"; search.replacement = "鳥"
        search.refresh(document: state.workspaceModel.document, scope: state.workSearchScope)
        try await Task.sleep(for: .milliseconds(450))
        editor.setMarkedText("犬", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 1, length: 0))
        #expect(editor.hasMarkedText())
        #expect(state.workspaceModel.document == document)
        #expect(await !(search.replace(using: state.workReplacementHost)))
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "猫犬")
        #expect(state.selectedEpisode?.content == "猫犬")
        #expect(try await application.openLocal(workID: work).document == state.workspaceModel.document)
        #expect(!search.canUndo)
    }

    private func makeEditorWindow(state: AppState) async throws -> NSWindow {
        let view = NSHostingView(rootView: EditorPaneView().environment(state).environment(state.workspaceModel)
            .environment(EditorSettings(userDefaults: makeIsolatedTestUserDefaults(), appearanceApplier: { _ in }))
            .environment(EditorSearchSession()).environment(state.editorCommandSession))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        view.layoutSubtreeIfNeeded()
        #expect(state.editorCommandSession.hasActiveEditorSurface)
        return window
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView {
            return text
        }
        return view.subviews.lazy.compactMap { findTextView(in: $0) }.first
    }
}
