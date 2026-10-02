import AppKit
@testable import EditorKit
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelSyncV2Store
import SwiftUI
import Testing

@MainActor
@Suite("Save preserves native editing position", .serialized)
struct SaveEditorPositionTests {
    @Test("保存を繰り返しても選択・スクロール・Undo履歴を動かさない", arguments: [false, true], [0, 4])
    func savePreservesSelectionAndViewport(synchronized: Bool, selectionLength: Int) async throws {
        let fixture = try await makeFixture(synchronized: synchronized)
        defer { fixture.close() }
        let editor = fixture.editor
        let scroll = fixture.scroll
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: (fixture.body as NSString).length, length: 0))
        editor.insertText("追記", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        undo.undo()
        #expect(editor.string == fixture.body)
        #expect(undo.canRedo)
        let selection = NSRange(
            location: (fixture.body as NSString).range(of: "100 保存").location,
            length: selectionLength
        )
        editor.setSelectedRange(selection)
        editor.scrollRangeToVisible(selection)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        let originalOrigin = scroll.contentView.bounds.origin
        let originalGeneration = fixture.state.editorContentGeneration
        #expect(originalOrigin.y > 100)
        for iteration in 0 ..< 3 {
            let previousReadCount = await fixture.configuration.remote.recordedHeadReads().count
            await fixture.state.saveAndSyncCurrentWork()
            if synchronized {
                try await eventuallyMac {
                    await fixture.configuration.remote.recordedHeadReads().count > previousReadCount
                }
                if iteration == 0 {
                    try await waitForRemoteUpdate(fixture)
                } else {
                    try await eventuallyMac {
                        await fixture.application.uiState(workID: fixture.workID)?.remoteProgress == .noChanges
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(150))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            #expect(editor.string == fixture.body)
            #expect(editor.selectedRange() == selection)
            #expect(abs(scroll.contentView.bounds.origin.y - originalOrigin.y) < 0.5)
            #expect(fixture.window.firstResponder === editor)
            #expect(editor.window === fixture.window)
            #expect(fixture.state.saveState == .saved)
            #expect(fixture.state.editorContentGeneration == originalGeneration)
            #expect(undo.canRedo)
        }
        #expect(await fixture.configuration.remote.recordedOperations().isEmpty)
        if synchronized {
            #expect(await fixture.configuration.remote.recordedHeadReads().contains(fixture.workID))
            let store = try LocalSyncV2Store(root: fixture.configuration.localRoot.url, policy: .openExisting)
            let scope = V2LocalWorkScope.bound(V2AccountBinding(
                accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server"
            ))
            #expect(try await store.pendingIntents(scope: scope, workID: fixture.workID).isEmpty)
            #expect(try await store.allSealedCommands(scope: scope, workID: fixture.workID).isEmpty)
            #expect(try await store.workSummary(workID: fixture.workID, scope: scope).acknowledgedHeadGeneration == 2)
            await store.close()
        }
        undo.redo()
        #expect(editor.string == fixture.body + "追記")
        undo.undo()
        #expect(editor.string == fixture.body)
    }

    @Test("IME変換中と実insertTextでの確定後に保存しても入力位置を保つ", arguments: [false, true])
    func savePreservesIMEPosition(commitBeforeSaving: Bool) async throws {
        let fixture = try await makeFixture(synchronized: false)
        defer { fixture.close() }
        let editor = fixture.editor
        let location = (fixture.body as NSString).range(of: "100 保存").location
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.setMarkedText(
            "へんかん",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(editor.hasMarkedText())
        if commitBeforeSaving {
            editor.insertText("変換", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(!editor.hasMarkedText())
        }
        editor.scrollRangeToVisible(editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        let text = editor.string
        let selection = editor.selectedRange()
        let origin = fixture.scroll.contentView.bounds.origin
        await fixture.state.saveAndSyncCurrentWork()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!editor.hasMarkedText())
        #expect(editor.string == text)
        #expect(editor.selectedRange() == selection)
        #expect(abs(fixture.scroll.contentView.bounds.origin.y - origin.y) < 0.5)
        #expect(fixture.state.selectedEpisode?.content == text)
        #expect(fixture.window.firstResponder === editor)
        let reopened = try await fixture.application.openLocal(workID: fixture.workID)
        #expect(reopened.document?.chapters.first?.episodes.first?.content == text)
    }

    private func waitForRemoteUpdate(_ fixture: Fixture) async throws {
        try await eventuallyMac {
            let adoption = try await fixture.application.pendingAdoption(workID: fixture.workID)
            let reads = await fixture.configuration.remote.recordedUpdateReads()
            let progress = await fixture.application.uiState(workID: fixture.workID)?.remoteProgress
            return adoption == nil && reads == [fixture.workID] && (progress == .noChanges || progress == .idle)
        }
    }
}

private extension SaveEditorPositionTests {
    @MainActor
    struct Fixture {
        let configuration: TestRuntimeConfiguration
        let application: SyncV2Application
        let state: AppState
        let workID: WorkID
        let body: String
        let window: NSWindow
        let editor: NSTextView
        let scroll: NSScrollView
        let observation: Task<Void, Never>

        func close() {
            observation.cancel()
            state.cancelSnapshotSyncV2BackgroundOperations()
            window.close()
        }
    }

    private func makeFixture(synchronized: Bool) async throws -> Fixture {
        let configuration = try TestRuntimeConfiguration(account: synchronized ? TestAccount(
            accountID: "test-account",
            accountFence: "test-fence"
        ) : nil)
        let defaults = makeIsolatedTestUserDefaults()
        let state = AppState(
            dependencies: AppDependencies(userDefaults: defaults, snapshotSyncV2DocumentGate: MacSyncV2DocumentGate()),
            initialStartupState: .ready
        )
        let body = (0 ..< 200).map { "\($0) 保存しても執筆位置を保つための長い確認用の本文です。" }.joined(separator: "\n")
        let episode = Episode(title: "位置の確認", content: body)
        let chapter = Chapter(title: "第一章", episodes: [episode])
        let document = NovelDocument(title: "保存位置の確認", chapters: [chapter])
        let workID = WorkID(UUID())
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        state.snapshotSyncV2Application = application
        if synchronized {
            try await seedSynchronizedWork(configuration, document: document, workID: workID, createdAt: createdAt)
            let opened = try await application.openLocal(workID: workID)
            try state.installV2Document(#require(opened.document), workID: workID, createdAt: createdAt)
            state.authSession = makeMacV2Session(accountID: "test-account", fence: "test-fence")
            state.authUIState = .signedIn(accountID: "test-account")
            state.snapshotSyncCurrentWorkAccountState = .active
            state.snapshotSyncV2Session = await application.beginSession(workID: workID)
        } else {
            state.installV2Document(document, workID: workID, createdAt: createdAt)
            state.snapshotSyncCurrentWorkAccountState = .unbound
        }
        let observation = Task { await state.observeSnapshotSyncV2Status() }
        let (window, editor) = try await makeEditorWindow(state: state, body: body)
        let scroll = try #require(editor.enclosingScrollView)
        return Fixture(
            configuration: configuration,
            application: application,
            state: state,
            workID: workID,
            body: body,
            window: window,
            editor: editor,
            scroll: scroll,
            observation: observation
        )
    }

    private func makeEditorWindow(state: AppState, body: String) async throws -> (NSWindow, NSTextView) {
        let host = NSHostingView(rootView: EditorPaneView()
            .environment(state)
            .environment(EditorSettings(userDefaults: makeIsolatedTestUserDefaults(), appearanceApplier: { _ in }))
            .environment(EditorSearchSession())
            .environment(state.editorCommandSession))
        let window = InputTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == body })
        window.makeFirstResponder(editor)
        #expect((editor as? AnimatedCaretTextView)?.motionEnabled == true)
        return (window, editor)
    }

    /// 入力と保存は実経路を使い、バックグラウンドのテストでもカーソル表示を有効にする。
    private final class InputTestWindow: NSWindow {
        override var isKeyWindow: Bool {
            true
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func seedSynchronizedWork(
        _ configuration: TestRuntimeConfiguration,
        document: NovelDocument,
        workID: WorkID,
        createdAt: Date
    ) async throws {
        let local = try SnapshotCodec.encode(
            SnapshotModel(workId: workID, document: document, documentCreatedAt: createdAt),
            parents: []
        )
        let remote = try SnapshotCodec.encode(
            SnapshotModel(workId: workID, document: document, documentCreatedAt: createdAt),
            parents: [local.snapshotId]
        )
        let scope = V2LocalWorkScope.bound(V2AccountBinding(
            accountID: "test-account",
            accountFence: "test-fence",
            serverInstanceID: "test-server"
        ))
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let inbox = try V2RemoteSnapshot(
            workID: workID,
            encoded: local,
            expectedCurrentSnapshotID: nil,
            expectedLocalGeneration: 0,
            expectedRemoteHead: V2RemoteHead(snapshotID: local.snapshotId, generation: 1)
        )
        try await store.stageRemote(inbox, scope: scope)
        try await store.verifyInbox(inboxID: inbox.inboxID, scope: scope)
        try await store.adoptInbox(inboxID: inbox.inboxID, scope: scope)
        await store.close()
        await configuration.remote.setHeadHandler { _ in
            try SyncV2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
        }
        await configuration.remote.setUpdateHandler { _ in
            try SyncV2RemoteInbox(
                inboxID: UUID(), workID: workID, headSnapshotID: remote.snapshotId,
                snapshots: [local, remote], expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                expectedRemoteHead: SyncV2RemoteHead(snapshotID: remote.snapshotId, generation: 2)
            )
        }
    }
}
