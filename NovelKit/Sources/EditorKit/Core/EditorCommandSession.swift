import Foundation
import Observation

/// 本文エディタへ明示的な操作を配送するcommand。
///
/// AppKitのテキストビューを公開せず、選択範囲の取得と置換を同じIDで対応付ける。
public enum EditorCommand: Sendable, Equatable {
    case requestSelectionSnapshot(UUID)
    case replaceSelection(id: UUID, text: String)

    var id: UUID {
        switch self {
        case let .requestSelectionSnapshot(id), let .replaceSelection(id: id, text: _):
            id
        }
    }
}

/// `EditorCommand`で取得した選択範囲のスナップショット。
public struct EditorSelectionSnapshot: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let range: NSRange

    public init(id: UUID, text: String, range: NSRange) {
        self.id = id
        self.text = text
        self.range = range
    }
}

/// SwiftUIとプラットフォームAdapterの間でEditor commandを配送する一時状態。
///
/// 本文・選択の正はAdapter内のテキストビューに置き、ここにはcommandと結果だけを持つ。
@MainActor
@Observable
public final class EditorCommandSession {
    public private(set) var pendingCommand: EditorCommand?
    public private(set) var selectionSnapshot: EditorSelectionSnapshot?
    public private(set) var rejectedCommandID: UUID?
    public private(set) var hasNonEmptySelection = false

    /// 作品切替・復元・終了前の境界で、現在のエディタが入力を確定して
    /// 一時的に編集を停止しているか。AppKit の型は公開APIへ出さず、
    /// Adapter が登録するクロージャだけを保持する。
    public private(set) var isDocumentTransitionPrepared = false

    private struct DocumentLifecycleHandler {
        let id: UUID
        let prepare: () -> Bool
        let resume: () -> Void
    }

    private var documentLifecycleHandler: DocumentLifecycleHandler?

    public init() {}

    @discardableResult
    public func requestSelectionSnapshot() -> UUID {
        let id = UUID()
        guard !isDocumentTransitionPrepared else {
            rejectTransaction(id: id)
            return id
        }

        // 選択snapshotは一度に一つのtransactionだけが所有する。
        // 前回値を残すと、作品遷移後の置換が古い選択へ結び付く可能性がある。
        selectionSnapshot = nil
        pendingCommand = .requestSelectionSnapshot(id)
        rejectedCommandID = nil
        return id
    }

    public func replaceSelection(id: UUID, text: String) {
        guard !isDocumentTransitionPrepared, selectionSnapshot?.id == id else {
            rejectTransaction(id: id)
            return
        }

        pendingCommand = .replaceSelection(id: id, text: text)
        rejectedCommandID = nil
    }

    /// 現在表示中のエディタでIME変換を確定し、確定本文をモデルへ同期してから
    /// 入力を停止する。エディタが表示されていない場合も安全に成功扱いとする。
    ///
    /// 作品の切替・復元・アプリ終了では、呼び出し後に保存を完了するまで
    /// ``resumeAfterDocumentTransition()`` を呼ばないこと。
    @discardableResult
    public func prepareForDocumentTransition() -> Bool {
        // request配送中だけでなく、選択取得後にsheetで入力を待っているtransactionも
        // 旧作品に属する。両方をここで破棄し、遷移先へ持ち越さない。
        if let transactionID = pendingCommand?.id ?? selectionSnapshot?.id {
            rejectTransaction(id: transactionID)
        }
        let didPrepare = documentLifecycleHandler?.prepare() ?? true
        isDocumentTransitionPrepared = didPrepare
        return didPrepare
    }

    /// 作品遷移が完了したか中止された後、表示中のエディタを再び編集可能にする。
    public func resumeAfterDocumentTransition() {
        isDocumentTransitionPrepared = false
        documentLifecycleHandler?.resume()
    }

    func registerDocumentLifecycleHandler(
        id: UUID,
        prepare: @escaping () -> Bool,
        resume: @escaping () -> Void
    ) {
        documentLifecycleHandler = DocumentLifecycleHandler(id: id, prepare: prepare, resume: resume)
        if isDocumentTransitionPrepared {
            isDocumentTransitionPrepared = prepare()
        }
    }

    func unregisterDocumentLifecycleHandler(id: UUID) {
        guard documentLifecycleHandler?.id == id else { return }
        documentLifecycleHandler = nil
    }

    func receiveSelectionSnapshot(_ snapshot: EditorSelectionSnapshot) {
        guard pendingCommand?.id == snapshot.id else { return }
        selectionSnapshot = snapshot
        pendingCommand = nil
    }

    func completeCommand(id: UUID) {
        guard pendingCommand?.id == id else { return }
        pendingCommand = nil
        if selectionSnapshot?.id == id {
            selectionSnapshot = nil
        }
    }

    func rejectCommand(id: UUID) {
        guard pendingCommand?.id == id else { return }
        rejectTransaction(id: id)
    }

    func updateSelectionAvailability(_ range: NSRange) {
        hasNonEmptySelection = range.length > 0
    }

    private func rejectTransaction(id: UUID) {
        if pendingCommand?.id == id {
            pendingCommand = nil
        }
        if selectionSnapshot?.id == id {
            selectionSnapshot = nil
        }
        rejectedCommandID = id
    }
}
