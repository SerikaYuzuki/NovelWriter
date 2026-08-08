// `MacTextAdapter`(docs/DESIGN.md 4.3)は、AppKit に触れるコードを EditorKit の
// 中に閉じ込めるための internal 実装である。iOS 向けコンパイル(→ D-013)を壊さない
// よう、必ず `#if canImport(AppKit)` で保護すること(docs/DESIGN.md 9.2)。
// このファイルは iOS ビルドでは中身が空になる。
#if canImport(AppKit)
import AppKit
import SwiftUI

/// `NSTextView`(TextKit 2)を SwiftUI から利用するための internal アダプタ。
///
/// `EditorView`(Public API)の実体。Public API に `NSTextView` を出さないという
/// ルール(docs/DESIGN.md 9.2)を守るため、この型自体は `public` にしない
/// (`EditorView.body` が `some View` として不透明に包んで返す)。
///
/// テキスト所有権ルール(docs/DESIGN.md 4.3, docs/DECISIONS.md D-005)の実装方針:
/// - 本文の流し込みは `chapterKey` が変化したとき(章切り替え時)のみ行う。
///   判定は `TextOwnershipPolicy.shouldLoadText` に切り出してある。SwiftUI の
///   通常の再描画(`updateNSView` の呼び直し)では `textView.string` を書き換えない。
/// - `textDidChange` は、テキストビューが変換中の未確定文字列(IME)を持っていない
///   ときだけ `onTextChange` を呼ぶ(`TextOwnershipPolicy.shouldNotifyTextChange`)。
/// - 章切り替え時、章専用の `UndoManager` を `removeAllActions()` でクリアし、
///   前章の undo 履歴が新しい章に効かないようにする。
struct MacTextAdapter: NSViewRepresentable {
    /// 本文とウィンドウ端の余白(docs/STYLE.md エディタ本文)。
    private static let contentInset = NSSize(width: 16, height: 16)

    let chapterKey: AnyHashable
    let initialText: String
    let selectionRequest: EditorSelectionRequest?
    let command: EditorCommand?
    let commandSession: EditorCommandSession
    let aiSelectionSession: EditorAISelectionSession?
    let configuration: EditorConfiguration
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() は常に NSTextView を documentView に持つ")
        }

        assertTextKit2(textView)
        configure(textView)

        textView.delegate = context.coordinator
        context.coordinator.onSelectionChange = { range, surfaceToken in
            commandSession.updateSelectionAvailability(range, from: surfaceToken)
        }
        context.coordinator.textView = textView
        context.coordinator.currentChapterKey = chapterKey

        textView.string = initialText
        context.coordinator.registerCommandSurface(with: commandSession)
        // 初回mountだけは、同じsessionに残っている旧surface leaseを意図的に
        // 引き継ぐ。update経路は別ownerを奪わないclaimに限定する。
        context.coordinator.activateAISelectionSurfaceOnMount(with: aiSelectionSession)
        commandSession.updateSelectionAvailability(
            textView.selectedRange(),
            from: context.coordinator.commandSurfaceToken
        )
        context.coordinator.applyConfigurationIfNeeded(configuration, to: textView, force: true)
        scrollView.backgroundColor = NSColor(hex: configuration.backgroundColorHex) ??
            NSColor(hex: EditorConfiguration.defaultBackgroundColorHex) ??
            .textBackgroundColor
        context.coordinator.undoManager.removeAllActions()
        context.coordinator.registerDocumentLifecycle(with: commandSession)

        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        // クロージャは SwiftUI の再描画のたびに再生成されるため、常に最新のものへ
        // 差し替える(Coordinator はビューのライフサイクルを通じて生き続ける)。
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onSelectionChange = { range, surfaceToken in
            commandSession.updateSelectionAvailability(range, from: surfaceToken)
        }
        context.coordinator.registerDocumentLifecycle(with: commandSession)

        guard let textView = context.coordinator.textView else { return }
        context.coordinator.registerCommandSurface(with: commandSession)
        context.coordinator.registerAISelectionSurface(with: aiSelectionSession)
        let shouldLoadText = TextOwnershipPolicy.shouldLoadText(
            previousChapterKey: context.coordinator.currentChapterKey,
            newChapterKey: chapterKey
        )

        if shouldLoadText {
            // 同じAdapter実体でも表示本文が変われば別surfaceとして扱い、旧話／旧ノートで
            // 取得した選択snapshotを新しい本文へ適用できないようにする。
            context.coordinator.advanceCommandSurface()
            context.coordinator.advanceAISelectionSurface()
            context.coordinator.currentChapterKey = chapterKey
            textView.string = initialText
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.applyConfigurationIfNeeded(configuration, to: textView, force: true)

            // 章切り替え: 前章の undo 履歴が新しい章に効いてはならない。
            context.coordinator.undoManager.removeAllActions()
        } else {
            context.coordinator.applyConfigurationIfNeeded(configuration, to: textView)
        }
        commandSession.updateSelectionAvailability(
            textView.selectedRange(),
            from: context.coordinator.commandSurfaceToken
        )

        if let scrollView = textView.enclosingScrollView {
            scrollView.backgroundColor = NSColor(hex: configuration.backgroundColorHex) ??
                NSColor(hex: EditorConfiguration.defaultBackgroundColorHex) ??
                .textBackgroundColor
        }
        context.coordinator.applySelectionRequestIfNeeded(selectionRequest, textView: textView)
        context.coordinator.applyEditorCommandIfNeeded(command, session: commandSession, textView: textView)
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) {
        coordinator.unregisterCommandSurface()
        coordinator.unregisterAISelectionSurface()
        coordinator.unregisterDocumentLifecycle()
    }

    /// `NSTextView` が TextKit 2 で構築されていることを検証する。
    ///
    /// `layoutManager` への直接アクセスは TextKit 1 互換レイヤーを生成させ、
    /// TextKit 2 を暗黙に無効化してしまう(docs/DECISIONS.md D-006)。この関数は
    /// `layoutManager` に一切触れず、`textLayoutManager` の存在だけを確認する。
    private func assertTextKit2(_ textView: NSTextView) {
        assert(
            textView.textLayoutManager != nil,
            "NSTextView が TextKit 1 にフォールバックしています。" +
                "layoutManager への直接アクセスが原因になっていないか確認してください(D-006)。"
        )
    }

    /// 日本語の長文執筆に適した、プレーンテキストのエディタとして設定する。
    private func configure(_ textView: NSTextView) {
        // プレーンテキスト。装飾はモデルの責務ではない。
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true

        // 執筆の邪魔になる自動整形は無効化する。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        // 幅追従・縦スクロールのみ。
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
    }

    /// `NSTextViewDelegate` を実装し、テキスト所有権ルールを守りながら
    /// モデルへの通知・undo管理を行う。
    ///
    /// `UndoManager` は Swift では `@MainActor` 隔離されているため、この型全体を
    /// `@MainActor` にする(SwiftUI の `NSViewRepresentable` 呼び出しはもともと
    /// メインスレッドで行われるため、実害はない)。
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: (String) -> Void
        var onSelectionChange: ((NSRange, EditorSurfaceToken) -> Void)?
        weak var textView: NSTextView?
        var currentChapterKey: AnyHashable?
        private var lastAppliedSelectionRequestID: UUID?
        private(set) var lastAppliedConfiguration: EditorConfiguration?
        private var deferredConfiguration: EditorConfiguration?
        private(set) var textStorageAttributeApplicationCount = 0
        private let documentLifecycleRegistrationID = UUID()
        private weak var documentLifecycleSession: EditorCommandSession?
        private weak var commandSurfaceSession: EditorCommandSession?
        private(set) var commandSurfaceToken = EditorSurfaceToken()
        let aiSelectionOwnerID = UUID()
        weak var aiSelectionSurfaceSession: EditorAISelectionSession?
        var aiSelectionSurfaceToken = EditorSurfaceToken()
        var aiContentRevision: UInt64 = 0
        var aiSelectionRevision: UInt64 = 0
        private var isPerformingUndoOrRedo = false

        /// 章専用の undo 管理。`NSResponder.undoManager`(ウィンドウ共有)には
        /// 頼らず、`undoManager(for:)` でこの専用インスタンスを返すことで、
        /// 章切り替え時に他のUIへ影響を与えずに履歴をクリアできる。
        let undoManager = UndoManager()

        /// EditorKit の既定プラグインパイプライン(docs/DESIGN.md 4.3): IMEGuard → Indent の順。
        /// `EditorView` の公開APIは変えず、プラグインは常にこの並びで有効にする。
        private let pipeline = EditorPluginPipeline(plugins: [IMEGuardPlugin(), IndentPlugin()])

        /// プラグインが確定した置換を `shouldChangeText` 経由で適用している最中かどうか。
        ///
        /// `NSTextView.shouldChangeText(in:replacementString:)` は undo 登録と delegate
        /// 通知を兼ねる唯一のゲートであり、内部でもう一度
        /// `textView(_:shouldChangeTextIn:replacementString:)` を呼び出す。このフラグで
        /// その再入を検知し、パイプラインを再実行せずそのまま許可することで、
        /// 自分自身の置換適用が無限に再帰するのを防ぐ。
        var isApplyingPluginReplacement = false

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerWillChange(_:)),
                name: .NSUndoManagerWillUndoChange,
                object: undoManager
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerWillChange(_:)),
                name: .NSUndoManagerWillRedoChange,
                object: undoManager
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerDidFinishChange(_:)),
                name: .NSUndoManagerDidUndoChange,
                object: undoManager
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoManagerDidFinishChange(_:)),
                name: .NSUndoManagerDidRedoChange,
                object: undoManager
            )
        }

        @objc private func undoManagerWillChange(_ notification: Notification) {
            guard notification.object as? UndoManager === undoManager else { return }
            isPerformingUndoOrRedo = true
        }

        @objc private func undoManagerDidFinishChange(_ notification: Notification) {
            guard notification.object as? UndoManager === undoManager else { return }
            defer { isPerformingUndoOrRedo = false }
            guard let textView else { return }
            notifyCommittedText(from: textView)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            // 自分自身が確定させた置換を適用中の再入呼び出し。パイプラインには
            // 通さず、そのまま許可する(上記 `isApplyingPluginReplacement` 参照)。
            guard !isApplyingPluginReplacement else { return true }
            guard let replacementString else { return true }

            let context = MacEditorContext(textView: textView)
            let action = pipeline.shouldChange(
                context: context,
                range: affectedCharRange,
                replacement: replacementString
            )

            switch action {
            case .allow, .allowSkippingRemaining:
                return true
            case let .replace(range, text, caretOffset):
                applyPluginReplacement(range: range, text: text, caretOffset: caretOffset, textView: textView)
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            advanceAIContentRevision()

            guard TextOwnershipPolicy.shouldNotifyTextChange(
                hasMarkedText: textView.hasMarkedText()
            ) else {
                // IME変換中は通知しない。変換確定後の textDidChange で
                // 最新の全文が届く(docs/DESIGN.md 4.3)。
                return
            }

            // 内部置換が発生させた再入通知は、外側の変更処理が最終本文を通知する。
            // ここで再度後処理や onTextChange を行うと、IME確定後に中間本文が通知される。
            guard !isApplyingPluginReplacement else { return }
            // Undo / Redo中のdelegate通知は、操作完了通知で最終本文を一度だけ同期する。
            guard !isPerformingUndoOrRedo else { return }

            synchronizeCommittedText(from: textView)
        }

        /// 作品遷移前に、表示中の未確定入力を旧作品のモデルへ同期して入力を止める。
        /// `unmarkText()` 自体がdelegate通知を発生させないIME実装もあるため、
        /// 確定後の全文はこの境界から明示的にも通知する。
        func prepareForDocumentTransition() -> Bool {
            // 遷移が中止されて同じ本文へ戻る場合も、遷移前に取得したAI結果を
            // 再利用しない。AI専用surfaceだけを更新し、notation commandの
            // owner leaseや本文のUndo履歴には触れない。
            advanceAISelectionSurface()
            guard let textView else { return true }
            if textView.hasMarkedText() {
                textView.unmarkText()
            }
            guard !textView.hasMarkedText() else { return false }
            synchronizeCommittedText(from: textView)
            textView.isEditable = false
            return true
        }

        func resumeAfterDocumentTransition() {
            textView?.isEditable = true
        }

        private func synchronizeCommittedText(from textView: NSTextView) {
            guard !textView.hasMarkedText(), !isApplyingPluginReplacement else { return }

            pipeline.didChange(context: MacEditorContext(textView: textView))

            if case let .replace(range, text, caretOffset) = IndentRules.postChangeAction(
                in: textView.string,
                caretLocation: textView.selectedRange().location
            ) {
                // IMEの確定挿入とR5の後処理を別Undo単位にする。これによりUndo一回で
                // 字下げだけが戻り、確定した鉤括弧は残る。
                textView.breakUndoCoalescing()
                _ = applyInternalReplacement(
                    range: range,
                    text: text,
                    caretOffset: caretOffset,
                    textView: textView
                )
            }

            notifyCommittedText(from: textView)
        }

        /// plugin / command / Undoが確定した最終本文だけをモデルへ渡す。
        /// 通常入力向けのpipelineやR5後処理は再実行しない。
        func notifyCommittedText(from textView: NSTextView) {
            guard !textView.hasMarkedText(), !isApplyingPluginReplacement else { return }
            onTextChange(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            advanceAISelectionRevision()
            onSelectionChange?(textView.selectedRange(), commandSurfaceToken)
        }

        func undoManager(for _: NSTextView) -> UndoManager? {
            undoManager
        }

        /// 本文を流し直さず、設定が変わったときだけ表示属性を更新する。
        ///
        /// IME 変換中は marked text の表示属性を乱さないよう適用を保留し、次の
        /// `updateNSView` で同じ設定が渡されたときに反映する。
        func applyConfigurationIfNeeded(
            _ configuration: EditorConfiguration,
            to textView: NSTextView,
            force: Bool = false
        ) {
            let needsApply = force || lastAppliedConfiguration != configuration

            if textView.hasMarkedText() {
                if needsApply {
                    deferredConfiguration = configuration
                }
                return
            }

            guard needsApply || deferredConfiguration == configuration else {
                deferredConfiguration = nil
                return
            }

            apply(configuration, to: textView)
            lastAppliedConfiguration = configuration
            deferredConfiguration = nil
        }

        /// 検索ジャンプなど、外部からの「選択だけ変える」依頼を適用する。
        ///
        /// 本文そのものは書き換えず、`textView.string` の範囲内であることを確認してから
        /// 選択・スクロール・フォーカスだけを更新する。
        func applySelectionRequestIfNeeded(_ request: EditorSelectionRequest?, textView: NSTextView) {
            guard let request, lastAppliedSelectionRequestID != request.id else { return }
            guard Range(request.range, in: textView.string) != nil else { return }

            lastAppliedSelectionRequestID = request.id
            textView.setSelectedRange(request.range)
            textView.scrollRangeToVisible(request.range)
            textView.window?.makeFirstResponder(textView)
        }

        /// プラグインが確定した置換を、undo が正しく動く経路で適用する。
        ///
        /// `shouldChangeText(in:replacementString:)` を経由することで、実際のタイピングと
        /// 同じ経路で undo 登録と delegate 通知を行う。挿入するテキストには
        /// `typingAttributes` を明示的に適用し、置換挿入でフォント・行間が崩れない
        /// ようにする。
        private func applyPluginReplacement(
            range: NSRange,
            text: String,
            caretOffset: Int,
            textView: NSTextView
        ) {
            guard applyInternalReplacement(
                range: range,
                text: text,
                caretOffset: caretOffset,
                textView: textView
            ) else { return }
            notifyCommittedText(from: textView)
        }

        @discardableResult
        func applyInternalReplacement(
            range: NSRange,
            text: String,
            caretOffset: Int,
            textView: NSTextView
        ) -> Bool {
            guard let textStorage = textView.textStorage else { return false }

            isApplyingPluginReplacement = true
            defer { isApplyingPluginReplacement = false }

            guard textView.shouldChangeText(in: range, replacementString: text) else { return false }

            let attributedText = NSAttributedString(string: text, attributes: textView.typingAttributes)
            textStorage.replaceCharacters(in: range, with: attributedText)
            textView.didChangeText()

            textView.setSelectedRange(NSRange(location: range.location + caretOffset, length: 0))
            return true
        }

        /// 本文を流し直さず、表示属性だけを更新する。
        private func apply(_ configuration: EditorConfiguration, to textView: NSTextView) {
            let font = NSFont(name: configuration.fontName, size: configuration.fontSize) ??
                NSFont.systemFont(ofSize: configuration.fontSize)
            let textColor = NSColor(hex: configuration.textColorHex) ??
                NSColor(hex: EditorConfiguration.defaultTextColorHex) ??
                .labelColor
            let backgroundColor = NSColor(hex: configuration.backgroundColorHex) ??
                NSColor(hex: EditorConfiguration.defaultBackgroundColorHex) ??
                .textBackgroundColor
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineHeightMultiple = configuration.lineHeightMultiple

            textView.font = font
            textView.textColor = textColor
            textView.insertionPointColor = textColor
            textView.backgroundColor = backgroundColor
            textView.drawsBackground = true
            textView.enclosingScrollView?.backgroundColor = backgroundColor
            textView.defaultParagraphStyle = paragraphStyle
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
            textView.textContainerInset = MacTextAdapter.contentInset
            textView.textStorage?.addAttributes(
                [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraphStyle
                ],
                range: NSRange(location: 0, length: (textView.string as NSString).length)
            )
            textStorageAttributeApplicationCount += 1
        }
    }
}

extension MacTextAdapter.Coordinator {
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
            _ = session.activateEditorSurfaceIfUnowned(commandSurfaceToken)
            return
        }
        unregisterCommandSurface()
        commandSurfaceSession = session
        session.activateEditorSurface(commandSurfaceToken)
    }

    /// 同じCoordinatorが別の章／話／世界観ノートを表示するとき、surface tokenを
    /// 更新して旧本文の選択transactionを失効させる。
    func advanceCommandSurface() {
        guard let commandSurfaceSession else { return }
        let nextToken = EditorSurfaceToken()
        guard commandSurfaceSession.replaceActiveEditorSurface(
            from: commandSurfaceToken,
            with: nextToken
        ) else { return }
        commandSurfaceToken = nextToken
    }

    func unregisterCommandSurface() {
        commandSurfaceSession?.deactivateEditorSurface(commandSurfaceToken)
        commandSurfaceSession = nil
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("#")
        guard normalized.count == 6, let value = Int(normalized, radix: 16) else { return nil }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
#endif
