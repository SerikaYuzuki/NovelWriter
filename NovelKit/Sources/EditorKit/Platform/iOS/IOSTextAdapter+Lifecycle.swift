#if canImport(UIKit) && !canImport(AppKit)
import UIKit

extension IOSTextAdapter.Coordinator {
    func registerDocumentLifecycle(with session: EditorCommandSession) {
        let prepare = { [weak self] in self?.prepareForDocumentTransition() ?? true }
        let resume: () -> Void = { [weak self] in
            self?.resumeAfterDocumentTransition()
        }
        if documentLifecycleSession === session {
            _ = session.claimDocumentLifecycleHandlerIfUnowned(
                id: documentLifecycleRegistrationID,
                prepare: prepare,
                resume: resume
            )
            return
        }
        unregisterDocumentLifecycle()
        documentLifecycleSession = session
        session.registerDocumentLifecycleHandler(
            id: documentLifecycleRegistrationID,
            prepare: prepare,
            resume: resume
        )
    }

    func unregisterDocumentLifecycle() {
        documentLifecycleSession?.unregisterDocumentLifecycleHandler(id: documentLifecycleRegistrationID)
        documentLifecycleSession = nil
    }

    func registerCommandSurface(with session: EditorCommandSession) {
        if commandSurfaceSession === session {
            guard session.activateEditorSurfaceIfUnowned(commandSurfaceToken) else { return }
            registerCommittedTextCaptureHandler(with: session)
            return
        }
        unregisterCommandSurface()
        commandSurfaceSession = session
        session.activateEditorSurface(commandSurfaceToken)
        registerCommittedTextCaptureHandler(with: session)
    }

    func ownsActiveCommandSurface() -> Bool {
        guard let commandSurfaceSession else { return false }
        return commandSurfaceSession.isActiveEditorSurface(commandSurfaceToken)
    }

    func advanceCommandSurface() {
        guard let commandSurfaceSession else { return }
        let nextToken = EditorSurfaceToken()
        guard commandSurfaceSession.replaceActiveEditorSurface(
            from: commandSurfaceToken,
            with: nextToken
        ) else { return }
        commandSurfaceToken = nextToken
        registerCommittedTextCaptureHandler(with: commandSurfaceSession)
    }

    func unregisterCommandSurface() {
        commandSurfaceSession?.deactivateEditorSurface(commandSurfaceToken)
        commandSurfaceSession = nil
    }

    private func registerCommittedTextCaptureHandler(with session: EditorCommandSession) {
        session.registerCommittedTextCaptureHandler(for: commandSurfaceToken) { [weak self] in
            guard let textView = self?.textView else { return .notActive }
            guard textView.markedTextRange == nil else { return .compositionInProgress }
            return .captured(textView.text)
        }
    }
}
#endif
