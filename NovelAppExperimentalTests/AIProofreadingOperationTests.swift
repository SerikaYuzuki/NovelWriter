import EditorKit
import Foundation
@testable import FUMINIWAExperimental
import NovelAI
import NovelCore
import Testing

@MainActor
@Test("previewとconfirmed payloadはexactでlocal identityを含めない")
func exactPreviewAndPayloadExcludeLocalIdentity() async throws {
    let expectedResult = proofreadingResult()
    let harness = try makeHarness(immediateResult: expectedResult)

    harness.operation.preparePreview()
    let preview = try #require(harness.operation.preview)
    let expectedPreview = try AIRequestDraft(
        selectedText: sourceText,
        budget: .experimentalProofreading
    ).preview(for: testProviderDescriptor)

    #expect(harness.operation.phase == .preview)
    #expect(preview.selectedText.value == sourceText)
    #expect(preview.applicationPrompt == expectedPreview.applicationPrompt)
    #expect(preview.applicationResponseSchema == expectedPreview.applicationResponseSchema)
    #expect(preview.applicationPayload == expectedPreview.applicationPayload)

    harness.operation.confirmAndSend()
    await harness.operation.waitForCurrentRequest()

    let requests = await harness.providerProbe.recordedRequests()
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.outbound == preview.applicationPayload)

    let prompt = try #require(
        JSONSerialization.jsonObject(with: Data(request.outbound.applicationPrompt.utf8))
            as? [String: String]
    )
    #expect(Set(prompt.keys) == ["instruction", "instruction_id", "selected_text"])
    #expect(prompt["selected_text"] == sourceText)
    #expect(prompt["instruction"] == preview.applicationInstruction)
    #expect(prompt["instruction_id"] == preview.applicationInstructionID)

    let forbiddenLocalIdentity = [
        localDocumentURL.path,
        localDocumentURL.absoluteString,
        documentUUID.uuidString,
        chapterUUID.uuidString,
        episodeUUID.uuidString,
        editorTransactionUUID.uuidString
    ]
    for sentinel in forbiddenLocalIdentity {
        #expect(!request.outbound.applicationPrompt.localizedCaseInsensitiveContains(sentinel))
        #expect(!request.outbound.applicationResponseSchema.localizedCaseInsensitiveContains(sentinel))
    }

    #expect(harness.operation.phase == .result)
    #expect(harness.operation.resultPresentation?.result == expectedResult)
}

@MainActor
@Test("作品session変更後はproviderを開始しない")
func changedDocumentSessionPreventsProviderStart() async throws {
    let harness = try makeHarness()
    harness.operation.preparePreview()
    harness.documentContext.snapshot = documentSnapshot(generation: 2)

    harness.operation.confirmAndSend()

    #expect(harness.operation.phase == .invalidated)
    #expect(harness.operation.failure == .stale(.documentChanged))
    #expect(harness.operation.preview == nil)
    #expect(harness.operation.resultPresentation == nil)
    #expect(await harness.providerProbe.recordedRequests().isEmpty)
}

@MainActor
@Test("話変更後はproviderを開始しない")
func changedEpisodePreventsProviderStart() async throws {
    let harness = try makeHarness()
    harness.operation.preparePreview()
    harness.documentContext.snapshot = AIProofreadingDocumentSnapshot(
        session: documentSessionToken(generation: 1),
        chapterID: ChapterID(rawValue: chapterUUID),
        episodeID: EpisodeID(rawValue: changedEpisodeUUID)
    )

    harness.operation.confirmAndSend()

    #expect(harness.operation.phase == .invalidated)
    #expect(harness.operation.failure == .stale(.episodeChanged))
    #expect(await harness.providerProbe.recordedRequests().isEmpty)
}

@MainActor
@Test("Editor transaction変更後はproviderを開始しない")
func staleEditorSelectionPreventsProviderStart() async throws {
    let harness = try makeHarness()
    harness.operation.preparePreview()
    let editorError = EditorAISelectionError.stale(.sourceChanged)
    harness.editorSelection.validationError = editorError

    harness.operation.confirmAndSend()

    #expect(harness.operation.phase == .invalidated)
    #expect(harness.operation.failure == .stale(.editorChanged(editorError)))
    #expect(await harness.providerProbe.recordedRequests().isEmpty)
}

@MainActor
@Test("選択revision通知で未送信previewを即時無効化する")
func selectionRevisionInvalidatesPreviewImmediately() async throws {
    let harness = try makeHarness()
    harness.operation.preparePreview()
    let editorError = EditorAISelectionError.stale(.selectionChanged)
    harness.editorSelection.validationError = editorError

    harness.operation.refreshApplicability()
    harness.operation.confirmAndSend()

    #expect(harness.operation.phase == .invalidated)
    #expect(harness.operation.failure == .stale(.editorChanged(editorError)))
    #expect(harness.operation.preview == nil)
    #expect(await harness.providerProbe.recordedRequests().isEmpty)
}

@MainActor
@Test("同じ話を送信中に編集してもrequestは継続し完了結果だけをstaleにする")
func textChangeWhileRunningKeepsRequestAndMarksResultStale() async throws {
    let harness = try makeHarness()
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.providerProbe.waitUntilStarted()
    let editorError = EditorAISelectionError.stale(.contentChanged)
    harness.editorSelection.validationError = editorError

    harness.operation.refreshApplicability()
    let completion = try providerCompletion(for: proofreadingResult())
    await harness.providerProbe.complete(completion)
    await harness.operation.waitForCurrentRequest()

    #expect(harness.operation.phase == .result)
    #expect(harness.operation.resultPresentation?.staleReason == .editorChanged(editorError))
    #expect(await harness.providerProbe.recordedRequests().count == 1)
    #expect(await harness.providerProbe.recordedCancellationCount() == 0)
}

@MainActor
@Test("送信中の選択revision通知はrequestを継続し完了結果だけをstaleにする")
func selectionRevisionWhileRunningKeepsRequestAndMarksResultStale() async throws {
    let harness = try makeHarness()
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.providerProbe.waitUntilStarted()
    let editorError = EditorAISelectionError.stale(.selectionChanged)
    harness.editorSelection.validationError = editorError

    harness.operation.refreshApplicability()

    #expect(harness.operation.phase == .running)
    #expect(await harness.providerProbe.recordedCancellationCount() == 0)

    try await harness.providerProbe.complete(providerCompletion(for: proofreadingResult()))
    await harness.operation.waitForCurrentRequest()

    #expect(harness.operation.phase == .result)
    #expect(harness.operation.resultPresentation?.staleReason == .editorChanged(editorError))
    #expect(harness.operation.resultPresentation?.canApply == false)
    #expect(await harness.providerProbe.recordedRequests().count == 1)
}

@MainActor
@Test("valid resultは明示Applyで一度だけEditorへ置換する")
func validResultAppliesExactlyOnce() async throws {
    let expectedResult = proofreadingResult()
    let harness = try makeHarness(immediateResult: expectedResult)
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.operation.waitForCurrentRequest()

    #expect(harness.operation.phase == .result)
    #expect(harness.operation.resultPresentation?.result == expectedResult)

    harness.operation.applyResult()
    harness.operation.applyResult()

    #expect(harness.operation.phase == .applied)
    #expect(harness.editorSelection.replacements == [replacementText])
}

@MainActor
@Test("Apply自身の同期callbackは無視し、その後のUndoや本文編集でstaleにする")
func appliedResultIgnoresApplyCallbackThenBecomesStaleAfterTextChange() async throws {
    let harness = try makeHarness(immediateResult: proofreadingResult())
    harness.editorSelection.didReplace = { [weak operation = harness.operation] in
        operation?.refreshApplicability()
    }
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.operation.waitForCurrentRequest()

    harness.operation.applyResult()

    #expect(harness.operation.phase == .applied)
    #expect(harness.operation.resultPresentation?.staleReason == nil)

    harness.operation.refreshApplicability()

    #expect(
        harness.operation.resultPresentation?.staleReason ==
            .editorChanged(.stale(.contentChanged))
    )
}

@MainActor
@Test("Apply後に作品が変わると古い結果をstale表示にする")
func appliedResultBecomesStaleAfterDocumentChange() async throws {
    let harness = try makeHarness(immediateResult: proofreadingResult())
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.operation.waitForCurrentRequest()
    harness.operation.applyResult()

    harness.documentContext.snapshot = documentSnapshot(generation: 2)
    harness.operation.documentContextDidChange()

    #expect(harness.operation.phase == .applied)
    #expect(harness.operation.resultPresentation?.staleReason == .documentChanged)
    #expect(harness.operation.resultPresentation?.canApply == false)
}

@MainActor
@Test("Apply直前にEditorがstaleなら置換しない")
func staleEditorImmediatelyBeforeApplyPreventsReplacement() async throws {
    let harness = try makeHarness(immediateResult: proofreadingResult())
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.operation.waitForCurrentRequest()
    let editorError = EditorAISelectionError.stale(.selectionChanged)
    harness.editorSelection.validationError = editorError

    harness.operation.applyResult()

    #expect(harness.operation.phase == .result)
    #expect(harness.editorSelection.replacements.isEmpty)
    #expect(harness.operation.resultPresentation?.staleReason == .editorChanged(editorError))
    #expect(harness.operation.resultPresentation?.canApply == false)
}

@MainActor
@Test("結果表示後のIME開始通知は不可逆にstale化してApplyを無効にする")
func imeRevisionAfterResultPermanentlyDisablesApply() async throws {
    let harness = try makeHarness(immediateResult: proofreadingResult())
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.operation.waitForCurrentRequest()
    let editorError = EditorAISelectionError.stale(.imeComposing)
    harness.editorSelection.validationError = editorError

    harness.operation.refreshApplicability()

    #expect(harness.operation.phase == .result)
    #expect(harness.operation.resultPresentation?.staleReason == .editorChanged(editorError))
    #expect(harness.operation.resultPresentation?.canApply == false)

    harness.editorSelection.validationError = nil
    harness.operation.refreshApplicability()
    harness.operation.applyResult()

    #expect(harness.operation.resultPresentation?.staleReason == .editorChanged(editorError))
    #expect(harness.operation.resultPresentation?.canApply == false)
    #expect(harness.editorSelection.replacements.isEmpty)
}

@MainActor
@Test("cancel後の遅延resultをUIへ復活させない")
func delayedResultAfterCancellationIsIgnored() async throws {
    let harness = try makeHarness()
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.providerProbe.waitUntilStarted()

    harness.operation.cancel()
    await harness.operation.waitForCurrentRequest()
    let delayedCompletion = try providerCompletion(for: proofreadingResult())
    await harness.providerProbe.complete(delayedCompletion)
    await Task.yield()

    #expect(harness.operation.phase == .cancelled)
    #expect(harness.operation.preview == nil)
    #expect(harness.operation.progress == AIProofreadingProgress())
    #expect(harness.operation.resultPresentation == nil)
    #expect(harness.editorSelection.replacements.isEmpty)
    #expect(await harness.providerProbe.recordedRequests().count == 1)
    #expect(await waitForCancellationCount(harness.providerProbe) == 1)
}

@MainActor
@Test("実行中にpanelを閉じると表示中の機密内容を直ちに破棄する")
func dismissDuringRequestImmediatelyScrubsPresentation() async throws {
    let harness = try makeHarness()
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.providerProbe.waitUntilStarted()

    harness.operation.dismiss()

    #expect(!harness.operation.isPanelPresented)
    #expect(harness.operation.phase == .cancelling)
    #expect(harness.operation.preview == nil)
    #expect(harness.operation.progress == AIProofreadingProgress())
    #expect(harness.operation.resultPresentation == nil)

    await harness.operation.waitForCurrentRequest()
    #expect(harness.operation.phase == .cancelled)
}

@MainActor
@Test("執筆Editorから離れるとpreviewを無効化し実行中requestを取り消す")
func unavailableEditorInvalidatesPreviewAndCancelsRunningRequest() async throws {
    let previewHarness = try makeHarness()
    previewHarness.operation.preparePreview()

    previewHarness.operation.editorSurfaceDidBecomeUnavailable()

    #expect(previewHarness.operation.phase == .invalidated)
    #expect(
        previewHarness.operation.failure ==
            .stale(.editorChanged(.stale(.inactiveSurface)))
    )
    #expect(await previewHarness.providerProbe.recordedRequests().isEmpty)

    let runningHarness = try makeHarness()
    runningHarness.operation.preparePreview()
    runningHarness.operation.confirmAndSend()
    await runningHarness.providerProbe.waitUntilStarted()

    runningHarness.operation.editorSurfaceDidBecomeUnavailable()
    await runningHarness.operation.waitForCurrentRequest()

    #expect(runningHarness.operation.phase == .cancelled)
    #expect(await waitForCancellationCount(runningHarness.providerProbe) == 1)

    let resultHarness = try makeHarness(immediateResult: proofreadingResult())
    resultHarness.operation.preparePreview()
    resultHarness.operation.confirmAndSend()
    await resultHarness.operation.waitForCurrentRequest()

    resultHarness.operation.editorSurfaceDidBecomeUnavailable()
    resultHarness.operation.applyResult()

    #expect(
        resultHarness.operation.resultPresentation?.staleReason ==
            .editorChanged(.stale(.inactiveSurface))
    )
    #expect(resultHarness.editorSelection.replacements.isEmpty)

    let appliedHarness = try makeHarness(immediateResult: proofreadingResult())
    appliedHarness.operation.preparePreview()
    appliedHarness.operation.confirmAndSend()
    await appliedHarness.operation.waitForCurrentRequest()
    appliedHarness.operation.applyResult()

    appliedHarness.operation.editorSurfaceDidBecomeUnavailable()

    #expect(
        appliedHarness.operation.resultPresentation?.staleReason ==
            .editorChanged(.stale(.inactiveSurface))
    )
}

@MainActor
@Test("provider failureはpreviewと受信途中の機密表示を破棄する")
func providerFailureScrubsSensitivePresentation() async throws {
    let harness = try makeHarness()
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.providerProbe.waitUntilStarted()
    let unverifiedFragment = String(repeating: "受", count: 256)
    await harness.providerProbe.yieldReplacementDelta(unverifiedFragment)

    #expect(await waitForReceivedProgress(harness.operation) == unverifiedFragment)

    await harness.providerProbe.fail(.providerUnavailable)
    await harness.operation.waitForCurrentRequest()

    #expect(harness.operation.phase == .failed)
    #expect(harness.operation.failure == .request(.providerUnavailable))
    #expect(harness.operation.preview == nil)
    #expect(harness.operation.progress == AIProofreadingProgress())
    #expect(harness.operation.resultPresentation == nil)
}

@MainActor
@Test("shutdownはprovider runtimeのdrain完了を待つ")
func shutdownAwaitsRuntimeDrain() async throws {
    let drainProbe = RuntimeDrainProbe()
    let ignoredRouteDrainLog = RuntimeDrainLog()
    let harness = try makeHarness(runtimeShutdown: {
        await drainProbe.drain()
    })

    let shutdownTask = Task { @MainActor in
        await harness.operation.shutdown()
    }
    await drainProbe.waitUntilEntered()
    let secondShutdownTask = Task { @MainActor in
        await harness.operation.shutdown()
    }
    let ignoredRoute = try makeRoute(
        leaseID: replacementRouteLeaseUUID,
        probe: ProviderProbe(),
        runtimeShutdown: {
            await ignoredRouteDrainLog.record("late-route")
        }
    )
    harness.operation.updateRoute(ignoredRoute)
    harness.operation.preparePreview()

    let completedBeforeRelease = await drainProbe.hasCompleted()
    #expect(!completedBeforeRelease)
    #expect(harness.operation.phase == .idle)
    #expect(!harness.operation.isPanelPresented)

    await drainProbe.release()
    await shutdownTask.value
    await secondShutdownTask.value

    #expect(await drainProbe.hasCompleted())
    #expect(await drainProbe.recordedEntryCount() == 1)
    #expect(await ignoredRouteDrainLog.recordedRoutes().isEmpty)
    #expect(await harness.providerProbe.recordedRequests().isEmpty)
}

@MainActor
@Test("provider変更後も終了時に利用済みruntimeをすべてdrainする")
func shutdownDrainsEveryRegisteredRoute() async throws {
    let drainLog = RuntimeDrainLog()
    let harness = try makeHarness(runtimeShutdown: {
        await drainLog.record("primary")
    })
    let replacementProbe = ProviderProbe()
    let replacementRoute = try makeRoute(
        leaseID: replacementRouteLeaseUUID,
        probe: replacementProbe,
        disclosureRevision: "route-v2",
        runtimeShutdown: {
            await drainLog.record("replacement")
        }
    )

    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.providerProbe.waitUntilStarted()
    harness.operation.updateRoute(replacementRoute)

    await harness.operation.shutdown()

    #expect(await drainLog.recordedRoutes() == Set(["primary", "replacement"]))
    #expect(await waitForCancellationCount(harness.providerProbe) == 1)
}
