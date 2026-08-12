#if canImport(UIKit) && !canImport(AppKit)
import UIKit

extension IOSTextAdapter.Coordinator {
    func advanceAIContentRevision() {
        aiContentRevision &+= 1
        notifyActiveTransactionRevisionDidChange()
    }

    func advanceAISelectionRevision() {
        aiSelectionRevision &+= 1
        notifyActiveTransactionRevisionDidChange()
    }

    func activateAISelectionSurfaceOnMount(with session: EditorAISelectionSession?) {
        guard let session else {
            unregisterAISelectionSurface()
            return
        }

        if aiSelectionSurfaceSession !== session {
            unregisterAISelectionSurface()
            aiSelectionSurfaceSession = session
        }
        session.activateEditorSurface(makeAISelectionSurfaceHandler(token: aiSelectionSurfaceToken))
    }

    func registerAISelectionSurface(with session: EditorAISelectionSession?) {
        guard let session else {
            unregisterAISelectionSurface()
            return
        }

        if aiSelectionSurfaceSession !== session {
            unregisterAISelectionSurface()
            aiSelectionSurfaceSession = session
        }
        _ = session.claimEditorSurfaceIfUnowned(
            makeAISelectionSurfaceHandler(token: aiSelectionSurfaceToken)
        )
    }

    func advanceAISelectionSurface() {
        guard let aiSelectionSurfaceSession else { return }
        let currentToken = aiSelectionSurfaceToken
        let nextToken = EditorSurfaceToken()
        let handler = makeAISelectionSurfaceHandler(token: nextToken)
        guard aiSelectionSurfaceSession.replaceActiveEditorSurface(
            ownerID: aiSelectionOwnerID,
            from: currentToken,
            with: handler
        ) else { return }

        aiSelectionSurfaceToken = nextToken
        aiContentRevision = 0
        aiSelectionRevision = 0
    }

    func unregisterAISelectionSurface() {
        aiSelectionSurfaceSession?.deactivateEditorSurface(
            ownerID: aiSelectionOwnerID,
            token: aiSelectionSurfaceToken
        )
        aiSelectionSurfaceSession = nil
        aiSelectionSurfaceToken = EditorSurfaceToken()
        aiContentRevision = 0
        aiSelectionRevision = 0
    }

    private func makeAISelectionSurfaceHandler(
        token: EditorSurfaceToken
    ) -> EditorAISelectionSurfaceHandler {
        EditorAISelectionSurfaceHandler(
            ownerID: aiSelectionOwnerID,
            surfaceToken: token,
            capture: { [weak self] transactionID, sessionIdentity, leaseIdentity, expectedToken in
                guard let self else {
                    return .failure(.unavailable(.inactiveSurface))
                }
                return captureAISelection(
                    transactionID: transactionID,
                    sessionIdentity: sessionIdentity,
                    surfaceLeaseIdentity: leaseIdentity,
                    expectedToken: expectedToken
                )
            },
            validate: { [weak self] capability in
                guard let self else {
                    return .failure(.stale(.inactiveSurface))
                }
                return validateAISelection(capability)
            },
            replace: { [weak self] capability, text in
                guard let self else {
                    return .failure(.stale(.inactiveSurface))
                }
                return replaceAISelection(capability, with: text)
            }
        )
    }

    private func notifyActiveTransactionRevisionDidChange() {
        aiSelectionSurfaceSession?.activeTransactionRevisionDidChange(
            ownerID: aiSelectionOwnerID,
            token: aiSelectionSurfaceToken
        )
    }

    private func captureAISelection(
        transactionID: UUID,
        sessionIdentity: UUID,
        surfaceLeaseIdentity: UUID,
        expectedToken: EditorSurfaceToken
    ) -> Result<EditorAISelectionCapability, EditorAISelectionError> {
        guard expectedToken == aiSelectionSurfaceToken, let textView else {
            return .failure(.unavailable(.inactiveSurface))
        }
        guard textView.isEditable else {
            return .failure(.unavailable(.editorInactive))
        }
        guard textView.markedTextRange == nil else {
            return .failure(.unavailable(.imeComposing))
        }

        let range = textView.selectedRange
        guard range.length > 0 else {
            return .failure(.unavailable(.emptySelection))
        }
        guard let stringRange = Range(range, in: textView.text) else {
            return .failure(.unavailable(.invalidSelection))
        }

        return .success(
            EditorAISelectionCapability(
                id: transactionID,
                sessionIdentity: sessionIdentity,
                surfaceLeaseIdentity: surfaceLeaseIdentity,
                surfaceToken: expectedToken,
                contentRevision: aiContentRevision,
                selectionRevision: aiSelectionRevision,
                range: range,
                exactText: String(textView.text[stringRange])
            )
        )
    }

    private func validateAISelection(
        _ capability: EditorAISelectionCapability
    ) -> Result<Void, EditorAISelectionError> {
        guard capability.surfaceToken == aiSelectionSurfaceToken else {
            return .failure(.stale(.surfaceChanged))
        }
        guard let textView else {
            return .failure(.stale(.inactiveSurface))
        }
        guard textView.isEditable else {
            return .failure(.stale(.editorInactive))
        }
        guard textView.markedTextRange == nil else {
            return .failure(.stale(.imeComposing))
        }
        guard textView.selectedRange == capability.range else {
            return .failure(.stale(.rangeChanged))
        }
        guard let stringRange = Range(capability.range, in: textView.text) else {
            return .failure(.stale(.invalidRange))
        }
        guard String(textView.text[stringRange]) == capability.exactText else {
            return .failure(.stale(.sourceChanged))
        }
        guard capability.contentRevision == aiContentRevision else {
            return .failure(.stale(.contentChanged))
        }
        guard capability.selectionRevision == aiSelectionRevision else {
            return .failure(.stale(.selectionChanged))
        }
        return .success(())
    }

    private func replaceAISelection(
        _ capability: EditorAISelectionCapability,
        with text: String
    ) -> Result<Void, EditorAISelectionError> {
        let validation = validateAISelection(capability)
        guard case .success = validation else { return validation }
        guard let textView else {
            return .failure(.stale(.inactiveSurface))
        }

        guard applyInternalReplacement(
            range: capability.range,
            text: text,
            caretOffset: (text as NSString).length,
            textView: textView
        ) else {
            return .failure(.replacementRejected)
        }

        notifyCommittedText(from: textView)
        return .success(())
    }
}
#endif
