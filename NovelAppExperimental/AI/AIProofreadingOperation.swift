import Foundation
import NovelAI
import Observation

@MainActor
@Observable
final class AIProofreadingOperation {
    private struct LocalContext {
        let operationID: UUID
        let document: AIProofreadingDocumentSnapshot
        let editorSelection: AIEditorSelectionHandle
        let sourceDigest: AIProofreadingSourceDigest
        let routeLeaseID: UUID
        let disclosureRevision: String
    }

    private struct ActiveOperation {
        let context: LocalContext
        let preview: AIOutboundPreview
        let route: AIProviderRoute
        var result: AIResult?
    }

    private struct ProviderPresentationSnapshot {
        let descriptor: AIProviderDescriptor
        let disclosure: AIProviderDisclosureSnapshot
    }

    private(set) var phase: AIProofreadingPhase = .idle
    private(set) var preview: AIOutboundPreview?
    private(set) var progress = AIProofreadingProgress()
    private(set) var resultPresentation: AIProofreadingResultPresentation?
    private(set) var failure: AIProofreadingFailure?
    var isPanelPresented = false

    private let documentContext: AIProofreadingDocumentContextClient
    private let editorSelection: AIEditorSelectionClient
    private let budget: AIRequestBudget
    private var selectedRoute: AIProviderRoute
    private var activeOperation: ActiveOperation?
    private var terminalProviderPresentation: ProviderPresentationSnapshot?
    @ObservationIgnored private var runtimeRoutes: [UUID: AIProviderRoute]
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var requestTaskOperationID: UUID?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingResult = false
    private var isShuttingDown = false

    init(
        documentContext: AIProofreadingDocumentContextClient,
        editorSelection: AIEditorSelectionClient,
        route: AIProviderRoute,
        budget: AIRequestBudget = .experimentalProofreading
    ) {
        self.documentContext = documentContext
        self.editorSelection = editorSelection
        selectedRoute = route
        runtimeRoutes = [route.leaseID: route]
        self.budget = budget
    }

    var providerDescriptor: AIProviderDescriptor {
        activeOperation?.route.descriptor ??
            terminalProviderPresentation?.descriptor ??
            selectedRoute.descriptor
    }

    var providerDisclosure: AIProviderDisclosureSnapshot {
        activeOperation?.route.disclosure ??
            terminalProviderPresentation?.disclosure ??
            selectedRoute.disclosure
    }

    var isRequestInFlight: Bool {
        phase == .running || phase == .cancelling
    }

    func preparePreview() {
        guard !isShuttingDown else { return }
        isPanelPresented = true
        guard requestTask == nil else { return }
        resetPresentation()

        guard let document = documentContext.currentSnapshot() else {
            fail(.stale(.appUnavailable))
            return
        }
        let selection: AIEditorSelectionHandle
        switch editorSelection.capture() {
        case let .success(value):
            selection = value
        case let .failure(error):
            fail(.editor(error))
            return
        }

        do {
            let outboundPreview = try AIRequestDraft(
                selectedText: selection.selectedText,
                budget: budget
            ).preview(for: selectedRoute.descriptor)
            let context = LocalContext(
                operationID: UUID(),
                document: document,
                editorSelection: selection,
                sourceDigest: AIProofreadingSourceDigest(exactText: selection.selectedText),
                routeLeaseID: selectedRoute.leaseID,
                disclosureRevision: selectedRoute.disclosure.revision
            )
            activeOperation = ActiveOperation(
                context: context,
                preview: outboundPreview,
                route: selectedRoute,
                result: nil
            )
            preview = outboundPreview
            phase = .preview
        } catch let error as AIError {
            fail(.request(error))
        } catch {
            fail(.request(.invalidResponse))
        }
    }

    func confirmAndSend() {
        guard !isShuttingDown else { return }
        guard phase == .preview, var operation = activeOperation else { return }
        if let staleReason = validate(operation, checksRoute: true) {
            invalidate(staleReason)
            return
        }

        let confirmedRequest = operation.preview.confirmForSending()
        operation.result = nil
        activeOperation = operation
        progress = AIProofreadingProgress()
        failure = nil
        resultPresentation = nil
        phase = .running

        let operationID = operation.context.operationID
        let stream = operation.route.events(for: confirmedRequest)
        requestTaskOperationID = operationID
        requestTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.receive(event, operationID: operationID)
            }
            self?.requestDidFinish(operationID: operationID)
        }
    }

    func cancel() {
        guard isRequestInFlight else { return }
        rememberCurrentProviderPresentation()
        phase = .cancelling
        requestTask?.cancel()
    }

    func dismiss() {
        if isRequestInFlight {
            cancel()
            clearSensitivePresentation()
        } else {
            resetPresentation()
        }
        isPanelPresented = false
    }

    func documentContextDidChange() {
        guard let operation = activeOperation else { return }
        guard let staleReason = validate(operation, checksRoute: phase == .preview) else { return }

        switch phase {
        case .preview:
            invalidate(staleReason)
        case .running:
            cancel()
            clearSensitivePresentation()
        case .result:
            markResultStale(staleReason)
        case .applied:
            markResultStale(staleReason)
        default:
            break
        }
    }

    /// 執筆Editorが画面から外れたことを、App層から明示的に通知する。
    ///
    /// `selectedEpisodeID`などの作品identityは、人物・設定・世界観へ移っても変わらない。
    /// surfaceのdismantle順序にも依存せず、旧本文のpreview送信や実行継続を止める。
    func editorSurfaceDidBecomeUnavailable() {
        guard activeOperation != nil else { return }
        let reason = AIProofreadingStaleReason.editorChanged(.stale(.inactiveSurface))
        switch phase {
        case .preview:
            invalidate(reason)
        case .running:
            cancel()
            clearSensitivePresentation()
        case .result, .applied:
            markResultStale(reason)
        default:
            break
        }
    }

    /// 本文編集など、送信中は妨げず、送信前または結果表示後だけstale表示へ反映する。
    func refreshApplicability() {
        // AI置換のモデルcallbackはreplaceの同期区間内で一度発火する。この通知を
        // 「適用後の追加編集」と誤認しない。replace完了後の次の本文変更は下でstale化する。
        guard !isApplyingResult else { return }
        if phase == .applied {
            markResultStale(.editorChanged(.stale(.contentChanged)))
            return
        }
        guard let operation = activeOperation,
              let staleReason = validate(operation, checksRoute: phase == .preview) else { return }
        switch phase {
        case .preview:
            invalidate(staleReason)
        case .result:
            markResultStale(staleReason)
        default:
            break
        }
    }

    func applyResult() {
        guard phase == .result,
              let operation = activeOperation,
              let result = operation.result,
              resultPresentation?.canApply == true else { return }
        if let staleReason = validate(operation, checksRoute: false) {
            markResultStale(staleReason)
            return
        }
        guard result.replacement != operation.context.editorSelection.selectedText else { return }

        isApplyingResult = true
        let replacement = operation.context.editorSelection.replace(result.replacement)
        isApplyingResult = false
        switch replacement {
        case .success:
            phase = .applied
            if var presentation = resultPresentation {
                presentation.staleReason = nil
                resultPresentation = presentation
            }
        case let .failure(error):
            markResultStale(.editorChanged(error))
        }
    }

    func updateRoute(_ route: AIProviderRoute) {
        guard !isShuttingDown else { return }
        guard route.leaseID != selectedRoute.leaseID else { return }
        runtimeRoutes[route.leaseID] = route
        selectedRoute = route
        documentContextDidChange()
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShuttingDown = true
        if isRequestInFlight {
            cancel()
        }
        let requestTask = requestTask
        let routes = Array(runtimeRoutes.values)
        let task = Task {
            await requestTask?.value
            for route in routes {
                await route.shutdownAndDrainRuntime()
            }
        }
        shutdownTask = task
        await task.value
    }

    func waitForCurrentRequest() async {
        await requestTask?.value
    }
}

private extension AIProofreadingOperation {
    func receive(_ event: AIProviderEvent, operationID: UUID) {
        guard requestTaskOperationID == operationID,
              activeOperation?.context.operationID == operationID,
              phase == .running else { return }

        switch event {
        case .started:
            break
        case let .replacementDelta(delta):
            progress.unverifiedReplacement += delta
        case let .completed(result):
            activeOperation?.result = result
            let staleReason = activeOperation.flatMap { validate($0, checksRoute: false) }
            resultPresentation = AIProofreadingResultPresentation(
                source: activeOperation?.context.editorSelection.selectedText ?? "",
                result: result,
                staleReason: staleReason
            )
            phase = .result
        case let .failed(error):
            if error == .cancelled {
                rememberCurrentProviderPresentation()
                clearSensitivePresentation()
                phase = .cancelled
            } else {
                fail(.request(error))
            }
        }
    }

    func requestDidFinish(operationID: UUID) {
        guard requestTaskOperationID == operationID else { return }
        requestTask = nil
        requestTaskOperationID = nil
        if phase == .cancelling {
            rememberCurrentProviderPresentation()
            activeOperation = nil
            phase = .cancelled
            preview = nil
            progress = AIProofreadingProgress()
            resultPresentation = nil
            failure = nil
        }
    }

    private func validate(
        _ operation: ActiveOperation,
        checksRoute: Bool
    ) -> AIProofreadingStaleReason? {
        guard let currentDocument = documentContext.currentSnapshot() else {
            return .appUnavailable
        }
        guard currentDocument.session == operation.context.document.session else {
            return .documentChanged
        }
        let matchesEpisode = currentDocument.chapterID == operation.context.document.chapterID &&
            currentDocument.episodeID == operation.context.document.episodeID
        guard matchesEpisode else {
            return .episodeChanged
        }
        if checksRoute {
            let matchesRoute = selectedRoute.leaseID == operation.context.routeLeaseID &&
                selectedRoute.disclosure.revision == operation.context.disclosureRevision &&
                selectedRoute.descriptor == operation.preview.provider
            guard matchesRoute else {
                return .providerChanged
            }
        }
        let source = operation.context.editorSelection.selectedText
        let matchesSource = operation.context.sourceDigest == AIProofreadingSourceDigest(exactText: source) &&
            operation.preview.selectedText.value == source
        guard matchesSource else {
            return .sourceChanged
        }
        switch operation.context.editorSelection.validate() {
        case .success:
            return nil
        case let .failure(error):
            return .editorChanged(error)
        }
    }

    func markResultStale(_ reason: AIProofreadingStaleReason) {
        guard var presentation = resultPresentation else {
            invalidate(reason)
            return
        }
        presentation.staleReason = presentation.staleReason ?? reason
        resultPresentation = presentation
    }

    func invalidate(_ reason: AIProofreadingStaleReason) {
        rememberCurrentProviderPresentation()
        clearSensitivePresentation()
        phase = .invalidated
        failure = .stale(reason)
    }

    func fail(_ failure: AIProofreadingFailure) {
        rememberCurrentProviderPresentation()
        clearSensitivePresentation()
        self.failure = failure
        phase = .failed
    }

    func resetPresentation() {
        terminalProviderPresentation = nil
        clearSensitivePresentation()
        phase = .idle
        failure = nil
    }

    func clearSensitivePresentation() {
        activeOperation = nil
        preview = nil
        progress = AIProofreadingProgress()
        resultPresentation = nil
    }

    func rememberCurrentProviderPresentation() {
        guard terminalProviderPresentation == nil || activeOperation != nil else { return }
        let route = activeOperation?.route ?? selectedRoute
        terminalProviderPresentation = ProviderPresentationSnapshot(
            descriptor: route.descriptor,
            disclosure: route.disclosure
        )
    }
}

extension AIRequestBudget {
    static let experimentalProofreading = AIRequestBudget(
        maximumInputCharacters: absoluteMaximumInputCharacters,
        maximumInputUTF8Bytes: absoluteMaximumInputUTF8Bytes,
        maximumOutputCharacters: absoluteMaximumOutputCharacters,
        maximumOutputUTF8Bytes: absoluteMaximumOutputUTF8Bytes,
        maximumOutputTokens: 4096,
        timeoutSeconds: 30
    )
}
