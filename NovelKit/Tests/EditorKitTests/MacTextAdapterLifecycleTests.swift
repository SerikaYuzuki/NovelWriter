#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

extension MacTextAdapterIntegrationTests {
    @Test("active editor surfaceがない選択取得要求は即時拒否する")
    func selectionRequestWithoutActiveSurfaceIsRejected() {
        let session = EditorCommandSession()

        let commandID = session.requestSelectionSnapshot()

        #expect(!session.hasActiveEditorSurface)
        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
    }

    @Test("作品遷移前はIMEを旧本文へ確定し、保存完了まで入力を停止する")
    func documentTransitionCommitsIMEAndLocksEditor() {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerDocumentLifecycle(with: session)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        beginIMEComposition(in: textView)

        #expect(textView.hasMarkedText())
        #expect(harness.changes.received.isEmpty)
        #expect(session.prepareForDocumentTransition())

        #expect(!textView.hasMarkedText())
        #expect(harness.changes.received.last == textView.string)
        #expect(!textView.isEditable)
        #expect(session.isDocumentTransitionPrepared)

        session.resumeAfterDocumentTransition()
        #expect(textView.isEditable)
        #expect(!session.isDocumentTransitionPrepared)
    }

    @Test("作品遷移は処理中のEditor commandを旧作品側で拒否する")
    func documentTransitionRejectsPendingCommand() {
        let harness = makeHarness(initialText: "本文")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        let commandID = session.requestSelectionSnapshot()
        #expect(session.pendingCommand?.id == commandID)

        #expect(session.prepareForDocumentTransition())

        #expect(session.pendingCommand == nil)
        #expect(session.rejectedCommandID == commandID)
    }

    @Test("作品遷移は取得済み選択を破棄し、再開後も旧transactionを復活させない")
    func documentTransitionInvalidatesCapturedSelectionTransaction() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerDocumentLifecycle(with: session)
        harness.coordinator.registerCommandSurface(with: session)
        textView.setSelectedRange(NSRange(location: 0, length: 1))

        let commandID = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )
        _ = try #require(session.selectionSnapshot)

        #expect(session.prepareForDocumentTransition())
        #expect(session.selectionSnapshot == nil)
        #expect(session.pendingCommand == nil)
        #expect(session.rejectedCommandID == commandID)

        session.resumeAfterDocumentTransition()
        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
        #expect(textView.string == "猫と犬")
    }

    @Test("旧surfaceのsnapshotは同じ範囲・同じ本文でも新surfaceへ適用しない")
    func surfaceSwitchInvalidatesSelectionTransaction() throws {
        let oldSurface = makeHarness(initialText: "猫と犬")
        let newSurface = makeHarness(initialText: "猫と犬")
        let session = EditorCommandSession()
        let selectedRange = NSRange(location: 0, length: 1)

        oldSurface.coordinator.registerCommandSurface(with: session)
        oldSurface.textView.setSelectedRange(selectedRange)
        let commandID = session.requestSelectionSnapshot()
        oldSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: oldSurface.textView
        )
        _ = try #require(session.selectionSnapshot)

        newSurface.textView.setSelectedRange(selectedRange)
        newSurface.coordinator.registerCommandSurface(with: session)
        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        newSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: newSurface.textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
        #expect(oldSurface.textView.string == "猫と犬")
        #expect(newSurface.textView.string == "猫と犬")
        #expect(newSurface.changes.received.isEmpty)
    }

    @Test("旧surfaceの遅延advance・再登録・破棄後も新surfaceがcommandを処理できる")
    func staleSurfaceReregistrationCannotReclaimActiveSession() throws {
        let oldSurface = makeHarness(initialText: "猫と犬")
        let newSurface = makeHarness(initialText: "猫と犬")
        let session = EditorCommandSession()
        let selectedRange = NSRange(location: 0, length: 1)

        oldSurface.coordinator.registerCommandSurface(with: session)
        newSurface.coordinator.registerCommandSurface(with: session)
        oldSurface.coordinator.advanceCommandSurface()
        oldSurface.coordinator.registerCommandSurface(with: session)
        oldSurface.coordinator.unregisterCommandSurface()

        newSurface.textView.setSelectedRange(selectedRange)
        let commandID = session.requestSelectionSnapshot()
        newSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: newSurface.textView
        )
        _ = try #require(session.selectionSnapshot)

        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        newSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: newSurface.textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == nil)
        #expect(oldSurface.textView.string == "猫と犬")
        #expect(newSurface.textView.string == "｜猫《ねこ》と犬")
        #expect(newSurface.changes.received == ["｜猫《ねこ》と犬"])
    }

    @Test("active surface破棄後は以前のsurfaceがsessionを再claimしてcommandを処理できる")
    func priorSurfaceCanReclaimUnownedSession() throws {
        let priorSurface = makeHarness(initialText: "猫と犬")
        let activeSurface = makeHarness(initialText: "猫と犬")
        let session = EditorCommandSession()
        let selectedRange = NSRange(location: 0, length: 1)

        priorSurface.coordinator.registerCommandSurface(with: session)
        activeSurface.coordinator.registerCommandSurface(with: session)
        activeSurface.coordinator.unregisterCommandSurface()
        #expect(!session.hasActiveEditorSurface)

        priorSurface.coordinator.registerCommandSurface(with: session)
        #expect(session.hasActiveEditorSurface)
        priorSurface.textView.setSelectedRange(selectedRange)
        let commandID = session.requestSelectionSnapshot()
        priorSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: priorSurface.textView
        )
        _ = try #require(session.selectionSnapshot)

        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        priorSurface.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: priorSurface.textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == nil)
        #expect(priorSurface.textView.string == "｜猫《ねこ》と犬")
        #expect(priorSurface.changes.received == ["｜猫《ねこ》と犬"])
        #expect(activeSurface.textView.string == "猫と犬")
    }

    @Test("旧Coordinatorはsurfaceとlifecycleの解放後に両leaseを再claimできる")
    func priorCoordinatorReclaimsSurfaceAndLifecycleLeases() {
        let priorSurface = makeHarness(initialText: "旧本文")
        let activeSurface = makeHarness(initialText: "新本文")
        let session = EditorCommandSession()

        priorSurface.coordinator.registerDocumentLifecycle(with: session)
        priorSurface.coordinator.registerCommandSurface(with: session)
        activeSurface.coordinator.registerDocumentLifecycle(with: session)
        activeSurface.coordinator.registerCommandSurface(with: session)

        activeSurface.coordinator.unregisterCommandSurface()
        activeSurface.coordinator.unregisterDocumentLifecycle()
        #expect(!session.hasActiveEditorSurface)

        priorSurface.coordinator.registerDocumentLifecycle(with: session)
        priorSurface.coordinator.registerCommandSurface(with: session)
        #expect(session.hasActiveEditorSurface)

        let textView = priorSurface.textView
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        beginIMEComposition(in: textView)
        #expect(textView.hasMarkedText())

        #expect(session.prepareForDocumentTransition())

        #expect(!textView.hasMarkedText())
        #expect(priorSurface.changes.received.last == textView.string)
        #expect(!textView.isEditable)
        #expect(activeSurface.textView.isEditable)
        #expect(activeSurface.changes.received.isEmpty)
        #expect(session.isDocumentTransitionPrepared)
    }

    @Test("新surface切替後の旧surface selection eventはavailabilityを変更しない")
    func staleSurfaceSelectionEventDoesNotChangeAvailability() {
        let oldSurface = makeHarness(initialText: "猫と犬")
        let newSurface = makeHarness(initialText: "猫と犬")
        let session = EditorCommandSession()

        oldSurface.coordinator.registerCommandSurface(with: session)
        session.updateSelectionAvailability(
            NSRange(location: 0, length: 1),
            from: oldSurface.coordinator.commandSurfaceToken
        )
        #expect(session.hasNonEmptySelection)

        newSurface.coordinator.registerCommandSurface(with: session)
        #expect(!session.hasNonEmptySelection)
        session.updateSelectionAvailability(
            NSRange(location: 0, length: 1),
            from: oldSurface.coordinator.commandSurfaceToken
        )
        #expect(!session.hasNonEmptySelection)

        session.updateSelectionAvailability(
            NSRange(location: 0, length: 1),
            from: newSurface.coordinator.commandSurfaceToken
        )
        #expect(session.hasNonEmptySelection)
    }

    @Test("同じCoordinatorで話を切り替えると旧snapshotを同じ範囲・同じ本文にも適用しない")
    func chapterSwitchInvalidatesSelectionTransaction() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let textView = harness.textView
        let session = EditorCommandSession()
        let selectedRange = NSRange(location: 0, length: 1)

        harness.coordinator.registerCommandSurface(with: session)
        textView.setSelectedRange(selectedRange)
        let commandID = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )
        _ = try #require(session.selectionSnapshot)

        harness.coordinator.advanceCommandSurface()
        textView.setSelectedRange(selectedRange)
        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
        #expect(textView.string == "猫と犬")
        #expect(harness.changes.received.isEmpty)
    }

    @Test("Adapter破棄後は旧surfaceのsnapshotを適用しない")
    func dismantledSurfaceInvalidatesSelectionTransaction() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let textView = harness.textView
        let session = EditorCommandSession()

        harness.coordinator.registerCommandSurface(with: session)
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        session.updateSelectionAvailability(
            textView.selectedRange(),
            from: harness.coordinator.commandSurfaceToken
        )
        #expect(session.hasActiveEditorSurface)
        #expect(session.hasNonEmptySelection)
        let commandID = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )
        _ = try #require(session.selectionSnapshot)

        harness.coordinator.unregisterCommandSurface()
        #expect(!session.hasActiveEditorSurface)
        #expect(!session.hasNonEmptySelection)
        session.replaceSelection(id: commandID, text: "｜猫《ねこ》")

        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == commandID)
        #expect(textView.string == "猫と犬")
        #expect(harness.changes.received.isEmpty)
    }

    @Test("作品遷移中に発行されたEditor commandは即時拒否する")
    func documentTransitionRejectsCommandsIssuedWhilePrepared() {
        let harness = makeHarness(initialText: "本文")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        #expect(session.prepareForDocumentTransition())

        let requestID = session.requestSelectionSnapshot()
        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == requestID)

        session.replaceSelection(id: requestID, text: "……")
        #expect(session.pendingCommand == nil)
        #expect(session.selectionSnapshot == nil)
        #expect(session.rejectedCommandID == requestID)
    }
}
#endif
