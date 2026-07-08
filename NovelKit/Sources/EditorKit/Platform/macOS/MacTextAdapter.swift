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
    let chapterKey: AnyHashable
    let initialText: String
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() は常に NSTextView を documentView に持つ")
        }

        assertTextKit2(textView)
        configure(textView)

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.currentChapterKey = chapterKey

        textView.string = initialText
        context.coordinator.undoManager.removeAllActions()

        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        // クロージャは SwiftUI の再描画のたびに再生成されるため、常に最新のものへ
        // 差し替える(Coordinator はビューのライフサイクルを通じて生き続ける)。
        context.coordinator.onTextChange = onTextChange

        guard let textView = context.coordinator.textView else { return }

        guard TextOwnershipPolicy.shouldLoadText(
            previousChapterKey: context.coordinator.currentChapterKey,
            newChapterKey: chapterKey
        ) else {
            // 同じ章のままの再描画。編集中の本文を外部から上書きしない
            // (テキスト所有権ルール, docs/DESIGN.md 4.3, D-005)。
            return
        }

        context.coordinator.currentChapterKey = chapterKey
        textView.string = initialText
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        // 章切り替え: 前章の undo 履歴が新しい章に効いてはならない。
        context.coordinator.undoManager.removeAllActions()
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

        // 日本語の長文執筆が読みやすいデフォルト(システムフォント16pt、行間やや広め)。
        let font = NSFont.systemFont(ofSize: 16)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.4
        textView.font = font
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraphStyle]
        textView.textContainerInset = NSSize(width: 12, height: 16)

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
        weak var textView: NSTextView?
        var currentChapterKey: AnyHashable?

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
        private var isApplyingPluginReplacement = false

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
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

            guard TextOwnershipPolicy.shouldNotifyTextChange(
                hasMarkedText: textView.hasMarkedText()
            ) else {
                // IME変換中は通知しない。変換確定後の textDidChange で
                // 最新の全文が届く(docs/DESIGN.md 4.3)。
                return
            }

            pipeline.didChange(context: MacEditorContext(textView: textView))
            onTextChange(textView.string)
        }

        func undoManager(for _: NSTextView) -> UndoManager? {
            undoManager
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
            isApplyingPluginReplacement = true
            defer { isApplyingPluginReplacement = false }

            guard textView.shouldChangeText(in: range, replacementString: text) else { return }

            let attributedText = NSAttributedString(string: text, attributes: textView.typingAttributes)
            textView.textStorage?.replaceCharacters(in: range, with: attributedText)
            textView.didChangeText()

            textView.setSelectedRange(NSRange(location: range.location + caretOffset, length: 0))
        }
    }
}

/// `EditorContext`(docs/DESIGN.md 4.4)を実際の `NSTextView` の状態から作るアダプタ。
///
/// `NSTextView` を直接プラグインへ渡さないための境界(docs/DESIGN.md 9.2)。
/// delegate 呼び出しのたびに、その時点のテキストビュー状態のスナップショットとして
/// 作り直す。プラグインは同期実行されるため、スナップショットでも一貫性は保てる。
/// `NSTextView` への参照を持たないことで、非隔離な `EditorContext` プロトコルと
/// AppKit の `@MainActor` 隔離の衝突も避けている。
private struct MacEditorContext: EditorContext {
    let string: String
    let isIMEComposing: Bool

    @MainActor
    init(textView: NSTextView) {
        string = textView.string
        isIMEComposing = textView.hasMarkedText()
    }

    func lineRange(at location: Int) -> NSRange {
        (string as NSString).lineRange(for: NSRange(location: location, length: 0))
    }
}
#endif
