#if canImport(UIKit) && !canImport(AppKit)
import SwiftUI
import UIKit

struct IOSPendingIMENewline {
    let sourceText: String
    let replacementRange: NSRange
    let surfaceToken: EditorSurfaceToken
}

struct IOSPendingUndoRegistration {
    let inverseRange: NSRange
    let replacedText: String
    let originalSelection: NSRange
    let surfaceToken: EditorSurfaceToken
}

/// 話ごとのUndo履歴を所有する、EditorKit内部だけの`UITextView`。
///
/// `textContainer: nil`で初期化するとiOS 16以降はTextKit 2になる。`layoutManager`は
/// 参照せず、生成直後に`textLayoutManager`の存在を検査する(D-006)。
@MainActor
final class IOSTextView: UITextView {
    weak var editorCoordinator: IOSTextAdapter.Coordinator?

    init() {
        super.init(frame: .zero, textContainer: nil)
    }

    override func unmarkText() {
        let wasComposing = markedTextRange != nil
        super.unmarkText()
        guard wasComposing,
              markedTextRange == nil,
              let coordinator = editorCoordinator else { return }
        let surfaceToken = coordinator.commandSurfaceToken

        // UIKitがunmark直後にselection／change通知を送らない経路も拾う。
        // 次のMainActor turnまで待ち、通知が先に同期を完了した場合はpending guardで
        // 二重適用しない。
        RunLoop.main.perform { [weak self, weak coordinator] in
            MainActor.assumeIsolated {
                guard let self,
                      let coordinator,
                      self.editorCoordinator === coordinator,
                      self.markedTextRange == nil else { return }
                coordinator.textViewDidEndComposition(self, surfaceToken: surfaceToken)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

/// `UITextView`(TextKit 2)をSwiftUIから利用するためのinternal adapter。
///
/// 本文の正は表示中の`UITextView`に置く。同じ話のSwiftUI updateでは本文を
/// 流し直さず、`chapterKey`が変わった場合だけ新しい本文をinstallする(D-005)。
struct IOSTextAdapter: UIViewRepresentable {
    let chapterKey: AnyHashable
    let initialText: String
    let selectionRequest: EditorSelectionRequest?
    let command: EditorCommand?
    let commandSession: EditorCommandSession
    let aiSelectionSession: EditorAISelectionSession?
    let selectionContextMenuCommands: [EditorSelectionContextMenuCommand]
    let configuration: EditorConfiguration
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeUIView(context: Context) -> IOSTextView {
        let textView = IOSTextView()
        assertTextKit2(textView)
        configure(textView)

        textView.delegate = context.coordinator
        context.coordinator.onSelectionChange = { range, surfaceToken in
            commandSession.updateSelectionAvailability(range, from: surfaceToken)
        }
        context.coordinator.selectionContextMenuCommands = selectionContextMenuCommands
        context.coordinator.textView = textView
        textView.editorCoordinator = context.coordinator
        context.coordinator.currentChapterKey = chapterKey

        textView.text = initialText
        context.coordinator.lastNotifiedCommittedText = initialText
        context.coordinator.registerCommandSurface(with: commandSession)
        context.coordinator.activateAISelectionSurfaceOnMount(with: aiSelectionSession)
        commandSession.updateSelectionAvailability(
            textView.selectedRange,
            from: context.coordinator.commandSurfaceToken
        )
        context.coordinator.applyConfigurationIfNeeded(configuration, to: textView, force: true)
        textView.undoManager?.removeAllActions()
        context.coordinator.registerDocumentLifecycle(with: commandSession)

        return textView
    }

    func updateUIView(_ textView: IOSTextView, context: Context) {
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onSelectionChange = { range, surfaceToken in
            commandSession.updateSelectionAvailability(range, from: surfaceToken)
        }
        context.coordinator.selectionContextMenuCommands = selectionContextMenuCommands
        context.coordinator.registerDocumentLifecycle(with: commandSession)
        context.coordinator.registerCommandSurface(with: commandSession)
        context.coordinator.registerAISelectionSurface(with: aiSelectionSession)

        let shouldLoadText = TextOwnershipPolicy.shouldLoadText(
            previousChapterKey: context.coordinator.currentChapterKey,
            newChapterKey: chapterKey
        )

        if shouldLoadText {
            context.coordinator.discardPendingPlatformEdits()
            context.coordinator.advanceCommandSurface()
            context.coordinator.advanceAISelectionSurface()
            context.coordinator.currentChapterKey = chapterKey
            textView.text = initialText
            context.coordinator.lastNotifiedCommittedText = initialText
            textView.selectedRange = NSRange(location: 0, length: 0)
            context.coordinator.applyConfigurationIfNeeded(configuration, to: textView, force: true)
            textView.undoManager?.removeAllActions()
        } else {
            context.coordinator.applyConfigurationIfNeeded(configuration, to: textView)
        }

        commandSession.updateSelectionAvailability(
            textView.selectedRange,
            from: context.coordinator.commandSurfaceToken
        )
        context.coordinator.applySelectionRequestIfNeeded(selectionRequest, textView: textView)
        context.coordinator.applyEditorCommandIfNeeded(command, session: commandSession, textView: textView)
    }

    static func dismantleUIView(_ textView: IOSTextView, coordinator: Coordinator) {
        textView.delegate = nil
        textView.editorCoordinator = nil
        coordinator.discardPendingPlatformEdits()
        coordinator.textView = nil
        coordinator.unregisterCommandSurface()
        coordinator.unregisterAISelectionSurface()
        coordinator.unregisterDocumentLifecycle()
    }

    private func assertTextKit2(_ textView: UITextView) {
        assert(
            textView.textLayoutManager != nil,
            "UITextViewがTextKit 1へフォールバックしています。" +
                "layoutManagerへアクセスしていないか確認してください(D-006)。"
        )
    }

    private func configure(_ textView: UITextView) {
        textView.allowsEditingTextAttributes = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive

        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.dataDetectorTypes = []

        textView.textContainer.widthTracksTextView = true
        textView.textContainerInset = IOSViewport.textContainerInset
        textView.contentInset.bottom = IOSViewport.bottomWritingClearance
        textView.verticalScrollIndicatorInsets.bottom = IOSViewport.bottomWritingClearance
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onTextChange: (String) -> Void
        var onSelectionChange: ((NSRange, EditorSurfaceToken) -> Void)?
        var selectionContextMenuCommands: [EditorSelectionContextMenuCommand] = []
        weak var textView: IOSTextView?
        var currentChapterKey: AnyHashable?
        var lastAppliedSelectionRequestID: UUID?
        var lastAppliedConfiguration: EditorConfiguration?
        var deferredConfiguration: EditorConfiguration?
        var textStorageAttributeApplicationCount = 0
        let documentLifecycleRegistrationID = UUID()
        weak var documentLifecycleSession: EditorCommandSession?
        weak var commandSurfaceSession: EditorCommandSession?
        var commandSurfaceToken = EditorSurfaceToken()
        let aiSelectionOwnerID = UUID()
        weak var aiSelectionSurfaceSession: EditorAISelectionSession?
        var aiSelectionSurfaceToken = EditorSurfaceToken()
        var aiContentRevision: UInt64 = 0
        var aiSelectionRevision: UInt64 = 0
        var isPerformingUndoOrRedo = false
        var hasPendingIMECommit = false
        var pendingIMENewline: IOSPendingIMENewline?
        var pendingUndoRegistrations: [IOSPendingUndoRegistration] = []
        var isPendingUndoFlushScheduled = false
        var observedInternalTextChange = false
        var lastNotifiedCommittedText: String?

        let pipeline = EditorPluginPipeline(plugins: [IMEGuardPlugin(), IndentPlugin()])

        /// `insertText` / `deleteBackward`がdelegateへ再入した場合にPluginを二重実行しない。
        var isApplyingPluginReplacement = false

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerWillChange(_:)),
                name: .NSUndoManagerWillUndoChange,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerWillChange(_:)),
                name: .NSUndoManagerWillRedoChange,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerDidFinishChange(_:)),
                name: .NSUndoManagerDidUndoChange,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerDidFinishChange(_:)),
                name: .NSUndoManagerDidRedoChange,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerDidCloseGroup(_:)),
                name: .NSUndoManagerDidCloseUndoGroup,
                object: nil
            )
        }

        @objc private func undoManagerWillChange(_ notification: Notification) {
            guard notification.object as? UndoManager === textView?.undoManager else { return }
            isPerformingUndoOrRedo = true
        }

        @objc private func undoManagerDidFinishChange(_ notification: Notification) {
            guard notification.object as? UndoManager === textView?.undoManager else { return }
            defer { isPerformingUndoOrRedo = false }
            guard let textView else { return }
            notifyCommittedText(from: textView)
        }

        @objc private func undoManagerDidCloseGroup(_ notification: Notification) {
            guard notification.object as? UndoManager === textView?.undoManager else { return }
            flushPendingUndoRegistrations()
        }
    }
}

@MainActor
enum IOSViewport {
    static let textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    static let bottomWritingClearance: CGFloat = 96

    static func reveal(range: NSRange, in textView: UITextView) {
        textView.scrollRangeToVisible(range)
    }
}

#endif
