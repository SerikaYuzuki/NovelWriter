#if canImport(AppKit)
import AppKit

extension MacTextAdapter.Coordinator {
    /// `makeNSView`の初回mount専用。新しく表示されたsurfaceをactive ownerにする。
    ///
    /// SwiftUIの遅延`updateNSView`から呼ぶと旧Coordinatorが新surfaceを奪い返せるため、
    /// update経路では``registerAISelectionSurface(with:)``だけを使う。
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

    /// SwiftUI update用。現在ownerのhandler更新またはowner不在時のreclaimだけを行う。
    ///
    /// `nil`や別sessionを保持していた旧Coordinatorへ遅延updateが届いても、すでに
    /// 別ownerがactiveなsessionを奪わない。
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

    /// 同じCoordinatorが別本文を表示する場合や作品遷移へ入る場合に、
    /// AI専用surfaceを更新して取得済みtransactionを不可逆にstale化する。
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

        // 同じCoordinatorが後でowner不在のsessionを再claimしても、dismantle前の
        // capabilityと同じtokenを再利用しない。
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
        guard !textView.hasMarkedText() else {
            return .failure(.unavailable(.imeComposing))
        }

        let range = textView.selectedRange()
        guard range.length > 0 else {
            return .failure(.unavailable(.emptySelection))
        }
        guard let stringRange = Range(range, in: textView.string) else {
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
                exactText: String(textView.string[stringRange])
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
        guard !textView.hasMarkedText() else {
            return .failure(.stale(.imeComposing))
        }
        guard textView.selectedRange() == capability.range else {
            return .failure(.stale(.rangeChanged))
        }
        guard let stringRange = Range(capability.range, in: textView.string) else {
            return .failure(.stale(.invalidRange))
        }
        guard String(textView.string[stringRange]) == capability.exactText else {
            return .failure(.stale(.sourceChanged))
        }
        // exact range/sourceを最終適用条件として先に照合したうえで、見た目が原状へ戻っていても
        // revision履歴が進んだtransactionは復活させない。
        guard capability.contentRevision == aiContentRevision else {
            return .failure(.stale(.contentChanged))
        }
        guard capability.selectionRevision == aiSelectionRevision else {
            return .failure(.stale(.selectionChanged))
        }
        return .success(())
    }

    /// 最終検査とexact range置換を、awaitを挟まない一つのMainActor同期区間で行う。
    private func replaceAISelection(
        _ capability: EditorAISelectionCapability,
        with text: String
    ) -> Result<Void, EditorAISelectionError> {
        let validation = validateAISelection(capability)
        guard case .success = validation else {
            return validation
        }
        guard let textView else {
            return .failure(.stale(.inactiveSurface))
        }

        // 直前・直後の通常入力とcoalesceさせず、AI置換だけを一回のUndo単位にする。
        textView.breakUndoCoalescing()
        guard applyInternalReplacement(
            range: capability.range,
            text: text,
            caretOffset: (text as NSString).length,
            textView: textView
        ) else {
            return .failure(.replacementRejected)
        }
        textView.breakUndoCoalescing()

        // applyInternalReplacement内のdelegate再入は抑止されているため、モデルcallbackは
        // ここから確定本文を一度だけ届ける。
        notifyCommittedText(from: textView)
        return .success(())
    }
}
#endif
