// AI選択transactionのPlatform統合は実NSTextViewを使うためmacOSだけで実行する。
#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

@MainActor
struct EditorAISelectionTransactionTests {
    private struct Harness {
        let textView: NSTextView
        let coordinator: MacTextAdapter.Coordinator
        let session: EditorAISelectionSession
        let changes: Changes
    }

    private final class Changes {
        var received: [String] = []
    }

    private func makeHarness(
        initialText: String,
        session: EditorAISelectionSession = EditorAISelectionSession()
    ) -> Harness {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 16)]
        textView.string = initialText

        let changes = Changes()
        let coordinator = MacTextAdapter.Coordinator(onTextChange: { changes.received.append($0) })
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.activateAISelectionSurfaceOnMount(with: session)

        return Harness(
            textView: textView,
            coordinator: coordinator,
            session: session,
            changes: changes
        )
    }

    private func failure(
        in result: Result<some Any, EditorAISelectionError>
    ) -> EditorAISelectionError? {
        guard case let .failure(error) = result else { return nil }
        return error
    }

    private func isSuccess(
        _ result: Result<some Any, EditorAISelectionError>
    ) -> Bool {
        guard case .success = result else { return false }
        return true
    }

    private func beginIMEComposition(in textView: NSTextView) {
        textView.setMarkedText(
            "か",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    @discardableResult
    private func applyUserReplacement(
        range: NSRange,
        text: String,
        in harness: Harness
    ) -> Bool {
        let textView = harness.textView
        guard let textStorage = textView.textStorage,
              textView.shouldChangeText(in: range, replacementString: text) else { return false }
        textStorage.replaceCharacters(
            in: range,
            with: NSAttributedString(string: text, attributes: textView.typingAttributes)
        )
        textView.didChangeText()
        textView.setSelectedRange(
            NSRange(location: range.location + (text as NSString).length, length: 0)
        )
        return true
    }

    @Test("AI transactionは絵文字後のexact UTF-16選択だけを公開する")
    func capturesExactUnicodeSelection() throws {
        let harness = makeHarness(initialText: "😀猫と犬")
        harness.textView.setSelectedRange(NSRange(location: 2, length: 1))

        let transaction = try harness.session.captureSelection().get()

        #expect(transaction.selectedText == "猫")
        #expect(isSuccess(harness.session.validate(transaction)))
    }

    @Test("active surfaceなし・inactive・空選択・IME中はcaptureを拒否する")
    func captureRejectsUnavailableEditorStates() {
        let inactiveSession = EditorAISelectionSession()
        #expect(
            failure(in: inactiveSession.captureSelection()) ==
                .unavailable(.inactiveSurface)
        )

        let harness = makeHarness(initialText: "本文")
        harness.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(
            failure(in: harness.session.captureSelection()) ==
                .unavailable(.emptySelection)
        )

        harness.textView.setSelectedRange(NSRange(location: 0, length: 1))
        harness.textView.isEditable = false
        #expect(
            failure(in: harness.session.captureSelection()) ==
                .unavailable(.editorInactive)
        )

        harness.textView.isEditable = true
        beginIMEComposition(in: harness.textView)
        #expect(
            failure(in: harness.session.captureSelection()) ==
                .unavailable(.imeComposing)
        )
    }

    @Test("AI置換はモデルcallback一回・AIだけのUndo一回・transaction一回限り")
    func replacementIsOneShotAndOneUndoUnit() throws {
        let harness = makeHarness(initialText: "前猫")
        harness.textView.setSelectedRange(NSRange(location: 1, length: 1))
        let transaction = try harness.session.captureSelection().get()

        #expect(isSuccess(harness.session.replace(transaction, with: "犬")))
        #expect(harness.textView.string == "前犬")
        #expect(harness.changes.received == ["前犬"])
        #expect(failure(in: harness.session.replace(transaction, with: "鳥")) == .alreadyApplied)

        harness.coordinator.undoManager.undo()
        #expect(harness.textView.string == "前猫")
        #expect(harness.changes.received == ["前犬", "前猫"])
    }

    @Test("本文を編集してUndoでexact sourceへ戻してもcontent revisionでstaleになる")
    func editThenUndoRemainsStale() throws {
        let harness = makeHarness(initialText: "猫と犬")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let transaction = try harness.session.captureSelection().get()

        #expect(applyUserReplacement(range: NSRange(location: 3, length: 0), text: "。", in: harness))
        harness.coordinator.undoManager.undo()
        harness.textView.setSelectedRange(NSRange(location: 0, length: 1))
        #expect(harness.textView.string == "猫と犬")

        #expect(
            failure(in: harness.session.validate(transaction)) ==
                .stale(.contentChanged)
        )
        #expect(
            failure(in: harness.session.replace(transaction, with: "ねこ")) ==
                .stale(.contentChanged)
        )
        #expect(harness.textView.string == "猫と犬")
    }

    @Test("選択を移動して同じrangeへ戻してもselection revisionでstaleになる")
    func selectionMoveThenReturnRemainsStale() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let originalRange = NSRange(location: 0, length: 1)
        harness.textView.setSelectedRange(originalRange)
        let transaction = try harness.session.captureSelection().get()

        harness.textView.setSelectedRange(NSRange(location: 2, length: 1))
        harness.coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: harness.textView)
        )
        harness.textView.setSelectedRange(originalRange)
        harness.coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: harness.textView)
        )

        #expect(
            failure(in: harness.session.validate(transaction)) ==
                .stale(.selectionChanged)
        )
        #expect(harness.textView.string == "猫と犬")
    }
}

extension EditorAISelectionTransactionTests {
    @Test("nilからshared sessionへの遅延updateは新surfaceを奪わない")
    func lateNilToSharedUpdateDoesNotStealActiveSurface() throws {
        let sharedSession = EditorAISelectionSession()
        let lateSurface = makeHarness(initialText: "旧本文")
        lateSurface.coordinator.registerAISelectionSurface(with: nil)

        let activeSurface = makeHarness(initialText: "新本文", session: sharedSession)
        activeSurface.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let transactionBeforeLateUpdate = try sharedSession.captureSelection().get()

        lateSurface.textView.setSelectedRange(NSRange(location: 0, length: 1))
        lateSurface.coordinator.registerAISelectionSurface(with: sharedSession)

        let transactionAfterLateUpdate = try sharedSession.captureSelection().get()
        #expect(transactionBeforeLateUpdate.selectedText == "新")
        #expect(transactionAfterLateUpdate.selectedText == "新")
        #expect(isSuccess(sharedSession.validate(transactionBeforeLateUpdate)))
        #expect(isSuccess(sharedSession.replace(transactionAfterLateUpdate, with: "現")))
        #expect(activeSurface.textView.string == "現本文")
        #expect(lateSurface.textView.string == "旧本文")
    }

    @Test("別sessionからshared sessionへの遅延updateは新surfaceを奪わない")
    func lateDifferentToSharedUpdateDoesNotStealActiveSurface() throws {
        let oldSession = EditorAISelectionSession()
        let sharedSession = EditorAISelectionSession()
        let lateSurface = makeHarness(initialText: "旧本文", session: oldSession)
        let activeSurface = makeHarness(initialText: "新本文", session: sharedSession)
        activeSurface.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let transactionBeforeLateUpdate = try sharedSession.captureSelection().get()

        lateSurface.textView.setSelectedRange(NSRange(location: 0, length: 1))
        lateSurface.coordinator.registerAISelectionSurface(with: sharedSession)

        let transactionAfterLateUpdate = try sharedSession.captureSelection().get()
        #expect(transactionBeforeLateUpdate.selectedText == "新")
        #expect(transactionAfterLateUpdate.selectedText == "新")
        #expect(isSuccess(sharedSession.validate(transactionBeforeLateUpdate)))
        #expect(
            failure(in: oldSession.captureSelection()) ==
                .unavailable(.inactiveSurface)
        )
        #expect(activeSurface.textView.string == "新本文")
        #expect(lateSurface.textView.string == "旧本文")
    }

    @Test("revision通知を迂回した変更もfixed rangeのexact source検査で拒否する")
    func finalValidationRejectsSourceMismatch() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let selectedRange = NSRange(location: 0, length: 1)
        harness.textView.setSelectedRange(selectedRange)
        let transaction = try harness.session.captureSelection().get()

        // productionの編集経路では必ずrevisionが進むが、最終検査がrevisionだけへ
        // 依存していないことを確認するため、delegate通知を意図的に迂回する。
        harness.textView.textStorage?.replaceCharacters(in: selectedRange, with: "狐")
        harness.textView.setSelectedRange(selectedRange)

        #expect(
            failure(in: harness.session.validate(transaction)) ==
                .stale(.sourceChanged)
        )
        #expect(harness.textView.string == "狐と犬")
    }

    @Test("IMEまたはinactiveを一度検出したtransactionは状態復帰後もstaleのまま")
    func transientUnsafeStatePermanentlyInvalidatesTransaction() throws {
        let imeHarness = makeHarness(initialText: "猫と犬")
        imeHarness.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let imeTransaction = try imeHarness.session.captureSelection().get()
        beginIMEComposition(in: imeHarness.textView)

        #expect(
            failure(in: imeHarness.session.validate(imeTransaction)) ==
                .stale(.imeComposing)
        )
        imeHarness.textView.unmarkText()
        #expect(
            failure(in: imeHarness.session.validate(imeTransaction)) ==
                .stale(.imeComposing)
        )

        let inactiveHarness = makeHarness(initialText: "猫と犬")
        inactiveHarness.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let inactiveTransaction = try inactiveHarness.session.captureSelection().get()
        inactiveHarness.textView.isEditable = false

        #expect(
            failure(in: inactiveHarness.session.validate(inactiveTransaction)) ==
                .stale(.editorInactive)
        )
        inactiveHarness.textView.isEditable = true
        #expect(
            failure(in: inactiveHarness.session.validate(inactiveTransaction)) ==
                .stale(.editorInactive)
        )
    }

    @Test("surface切替・dismantle・再claimで古いtransactionを復活させない")
    func surfaceLifecyclePermanentlyInvalidatesTransaction() throws {
        let sharedSession = EditorAISelectionSession()
        let oldSurface = makeHarness(initialText: "猫と犬", session: sharedSession)
        oldSurface.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let transaction = try sharedSession.captureSelection().get()

        let newSurface = makeHarness(initialText: "猫と犬", session: sharedSession)
        newSurface.coordinator.unregisterAISelectionSurface()

        // 旧Coordinatorがowner不在のsessionを再claimしても、session側のlease世代が
        // 変わっているため古いcapabilityは復活しない。
        oldSurface.coordinator.registerAISelectionSurface(with: sharedSession)
        #expect(
            failure(in: sharedSession.validate(transaction)) ==
                .stale(.surfaceChanged)
        )

        oldSurface.coordinator.unregisterAISelectionSurface()
        #expect(
            failure(in: sharedSession.captureSelection()) ==
                .unavailable(.inactiveSurface)
        )
        #expect(oldSurface.textView.string == "猫と犬")
        #expect(newSurface.textView.string == "猫と犬")
    }

    @Test("dismantled surfaceと別sessionは古いtransactionを拒否する")
    func dismantleAndDifferentSessionRejectTransaction() throws {
        let harness = makeHarness(initialText: "猫と犬")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let transaction = try harness.session.captureSelection().get()
        let foreignTransaction = try harness.session.captureSelection().get()

        MacTextAdapter.dismantleNSView(NSScrollView(), coordinator: harness.coordinator)
        #expect(
            failure(in: harness.session.validate(transaction)) ==
                .stale(.inactiveSurface)
        )

        let otherHarness = makeHarness(initialText: "猫と犬")
        otherHarness.textView.setSelectedRange(NSRange(location: 0, length: 1))
        #expect(
            failure(in: otherHarness.session.validate(foreignTransaction)) ==
                .stale(.sessionChanged)
        )
        #expect(otherHarness.textView.string == "猫と犬")
    }

    @Test("作品遷移を開始して中止しても遷移前のtransactionはstaleになる")
    func documentTransitionInvalidatesTransaction() throws {
        let harness = makeHarness(initialText: "猫と犬")
        let lifecycleSession = EditorCommandSession()
        harness.coordinator.registerDocumentLifecycle(with: lifecycleSession)
        harness.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let transaction = try harness.session.captureSelection().get()

        #expect(lifecycleSession.prepareForDocumentTransition())
        lifecycleSession.resumeAfterDocumentTransition()

        #expect(
            failure(in: harness.session.validate(transaction)) ==
                .stale(.surfaceChanged)
        )
        #expect(harness.textView.string == "猫と犬")
    }

    @Test("並列の二重applyでもexactly oneだけが本文を変更する")
    func concurrentDoubleApplyIsExactlyOnce() async throws {
        let harness = makeHarness(initialText: "猫と犬")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let transaction = try harness.session.captureSelection().get()
        let copiedTransaction = transaction

        let first = Task { @MainActor in
            harness.session.replace(transaction, with: "ねこ")
        }
        let second = Task { @MainActor in
            harness.session.replace(copiedTransaction, with: "ネコ")
        }
        let results = await [first.value, second.value]

        var successCount = 0
        var errors: [EditorAISelectionError] = []
        for result in results {
            switch result {
            case .success:
                successCount += 1
            case let .failure(error):
                errors.append(error)
            }
        }

        #expect(successCount == 1)
        #expect(errors == [.alreadyApplied])
        #expect(harness.changes.received.count == 1)
        #expect(harness.textView.string == "ねこと犬" || harness.textView.string == "ネコと犬")
    }
}
#endif
