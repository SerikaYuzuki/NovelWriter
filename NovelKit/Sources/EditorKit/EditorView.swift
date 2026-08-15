import SwiftUI

/// 本文エディタを提供する SwiftUI View。
///
/// macOS では `NSTextView`(TextKit 2)をラップした実装(`MacTextAdapter`)を表示する。
/// iOS / iPadOS では `UITextView`(TextKit 2)をラップした`IOSTextAdapter`を表示する。
///
/// Public API に `NSTextView` / `UITextView` を一切出さない(docs/DESIGN.md 9.2)。
///
/// ## テキスト所有権ルール(docs/DESIGN.md 4.3, docs/DECISIONS.md D-005)
///
/// 編集中の本文の「正」はプラットフォーム側のテキストビューであり、`EditorView` は
/// それを一方的に上書きしない。
///
/// - 本文の流し込みは ``chapterKey`` が変化したとき(= 章切り替え時)のみ行う。
///   同じ ``chapterKey`` のまま SwiftUI の再描画が走っても、``initialText`` は
///   再適用しない(編集中の内容を保持する)。
/// - 本文が変わるたびに ``onTextChange`` が呼ばれる。ただし IME 変換中は呼ばれない
///   (変換確定後の通知で最新の全文が届く)。
/// - 素朴な `Binding<String>` による双方向同期は行わない(D-005 で禁止)。
public struct EditorView: View {
    private let chapterKey: AnyHashable
    private let initialText: String
    private let selectionRequest: EditorSelectionRequest?
    private let commandSession: EditorCommandSession
    private let aiSelectionSession: EditorAISelectionSession?
    private let selectionContextMenuCommands: [EditorSelectionContextMenuCommand]
    private let configuration: EditorConfiguration
    private let isEditable: Bool
    private let onTextChange: (String) -> Void

    /// - Parameters:
    ///   - chapterKey: 表示中の章を一意に識別するキー(例: 章ID)。このキーが
    ///     変化したときだけ ``initialText`` を本文へ流し込む。呼び出し側は
    ///     章を切り替えるたびに異なるキーを渡すこと。
    ///   - initialText: ``chapterKey`` が変化したときにテキストビューへ流し込む
    ///     本文。編集中は無視される(所有権はテキストビュー側にあるため)。
    ///   - selectionRequest: 本文中の指定範囲を選択し、表示位置へスクロールする
    ///     リクエスト。検索ジャンプなど、本文を書き換えない操作に使う。
    ///   - commandSession: 選択取得・置換をAdapterへ配送する一時状態。本文のBindingには使わない。
    ///   - aiSelectionSession: 長時間のAI処理へ渡す選択範囲を、取得元のEditorへ
    ///     拘束するsession。未使用時は`nil`のままにする。
    ///   - selectionContextMenuCommands: 標準の本文context menuへ追加する、
    ///     AppKit非依存の選択範囲command。空配列なら標準menuだけを表示する。
    ///   - configuration: エディタの表示設定。本文は流し直さず、表示属性だけを更新する。
    ///   - isEditable: `false`なら本文の選択・copy・scrollは維持し、
    ///     通常入力とcommand置換だけを停止する。作品遷移の一時停止とは別に扱い、
    ///     遷移完了後もこの値が`false`なら編集可能に戻さない。
    ///   - onTextChange: 本文が変更されるたびに、そのときの全文を渡して呼び出される
    ///     コールバック。IME 変換中には呼ばれない。
    public init(
        chapterKey: AnyHashable,
        initialText: String,
        selectionRequest: EditorSelectionRequest? = nil,
        commandSession: EditorCommandSession = EditorCommandSession(),
        aiSelectionSession: EditorAISelectionSession? = nil,
        selectionContextMenuCommands: [EditorSelectionContextMenuCommand] = [],
        configuration: EditorConfiguration = EditorConfiguration(),
        isEditable: Bool = true,
        onTextChange: @escaping (String) -> Void
    ) {
        self.chapterKey = chapterKey
        self.initialText = initialText
        self.selectionRequest = selectionRequest
        self.commandSession = commandSession
        self.aiSelectionSession = aiSelectionSession
        self.selectionContextMenuCommands = selectionContextMenuCommands
        self.configuration = configuration
        self.isEditable = isEditable
        self.onTextChange = onTextChange
    }

    public var body: some View {
        #if canImport(AppKit)
        MacTextAdapter(
            chapterKey: chapterKey,
            initialText: initialText,
            selectionRequest: selectionRequest,
            command: commandSession.pendingCommand,
            commandSession: commandSession,
            aiSelectionSession: aiSelectionSession,
            selectionContextMenuCommands: selectionContextMenuCommands,
            configuration: configuration,
            isEditable: isEditable,
            onTextChange: onTextChange
        )
        #elseif canImport(UIKit)
        IOSTextAdapter(
            chapterKey: chapterKey,
            initialText: initialText,
            selectionRequest: selectionRequest,
            command: commandSession.pendingCommand,
            commandSession: commandSession,
            aiSelectionSession: aiSelectionSession,
            selectionContextMenuCommands: selectionContextMenuCommands,
            configuration: configuration,
            isEditable: isEditable,
            onTextChange: onTextChange
        )
        #endif
    }
}
