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

/// activeなEditor surfaceから、IME確定済みの最新全文を同期取得した結果。
///
/// 読み取り専用であり、本文、選択、Undo履歴を変更しない。`compositionInProgress`を
/// 空文字や直前のmodel値へfallbackさせず、呼び出し側へ明示する。
public enum EditorCommittedTextCaptureResult: Sendable, Equatable {
    case notActive
    case compositionInProgress
    case captured(String)
}

/// 選択transactionを、取得元のEditor surfaceへ拘束する内部token。
///
/// AppKit / UIKitの型や永続的な章IDをcommand APIへ持ち込まず、Adapterの実体または
/// 表示本文が切り替わったことだけを識別する。新しいsurfaceがactiveになると、古い
/// surfaceで取得した選択snapshotは同じ本文・同じ範囲でも失効する。
struct EditorSurfaceToken: Sendable, Hashable {
    let id = UUID()
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
    public private(set) var hasActiveEditorSurface = false

    /// 作品切替・復元・終了前の境界で、現在のエディタが入力を確定して
    /// 一時的に編集を停止しているか。AppKit の型は公開APIへ出さず、
    /// Adapter が登録するクロージャだけを保持する。
    public private(set) var isDocumentTransitionPrepared = false

    private struct DocumentLifecycleHandler {
        let id: UUID
        let prepare: () -> Bool
        let resume: () -> Void
    }

    private struct CommittedTextCaptureHandler {
        let surfaceToken: EditorSurfaceToken
        let capture: @MainActor () -> EditorCommittedTextCaptureResult
    }

    private var documentLifecycleHandler: DocumentLifecycleHandler?
    private var committedTextCaptureHandler: CommittedTextCaptureHandler?
    private var activeSurfaceToken: EditorSurfaceToken?
    private var pendingCommandSurfaceToken: EditorSurfaceToken?
    private var selectionSnapshotSurfaceToken: EditorSurfaceToken?

    public init() {}

    @discardableResult
    public func requestSelectionSnapshot() -> UUID {
        let id = UUID()
        guard !isDocumentTransitionPrepared, let activeSurfaceToken else {
            rejectTransaction(id: id)
            return id
        }

        // 選択snapshotは一度に一つのtransactionだけが所有する。
        // 前回値を残すと、作品遷移後の置換が古い選択へ結び付く可能性がある。
        selectionSnapshot = nil
        selectionSnapshotSurfaceToken = nil
        pendingCommand = .requestSelectionSnapshot(id)
        pendingCommandSurfaceToken = activeSurfaceToken
        rejectedCommandID = nil
        return id
    }

    public func replaceSelection(id: UUID, text: String) {
        guard let activeSurfaceToken else {
            rejectTransaction(id: id)
            return
        }
        let matchesActiveSurface = selectionSnapshot?.id == id &&
            selectionSnapshotSurfaceToken == activeSurfaceToken
        guard !isDocumentTransitionPrepared, matchesActiveSurface else {
            rejectTransaction(id: id)
            return
        }

        pendingCommand = .replaceSelection(id: id, text: text)
        pendingCommandSurfaceToken = activeSurfaceToken
        rejectedCommandID = nil
    }

    /// activeなEditorが所有するIME確定済み全文を、同期・読み取り専用で取得する。
    ///
    /// platform viewを公開せず、現在のsurface ownerが登録したhandlerだけを呼ぶ。
    /// active surfaceがない、またはownerに対応するhandlerがない場合は`notActive`を返す。
    public func captureActiveCommittedText() -> EditorCommittedTextCaptureResult {
        guard let activeSurfaceToken, let committedTextCaptureHandler else { return .notActive }
        guard committedTextCaptureHandler.surfaceToken == activeSurfaceToken else { return .notActive }
        return committedTextCaptureHandler.capture()
    }

    /// 指定surfaceが、このsessionの現在のactive ownerかを読み取り専用で確認する。
    ///
    /// tokenはEditorKit内部型のままとし、AppKitのviewやownerを公開APIへ漏らさない。
    func isActiveEditorSurface(_ surfaceToken: EditorSurfaceToken) -> Bool {
        activeSurfaceToken == surfaceToken
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

    /// owner不在時だけ既存Coordinatorのlifecycle handlerを復帰させる。
    /// 別surfaceのhandlerがactiveな間は、遅延updateからの奪取を許可しない。
    @discardableResult
    func claimDocumentLifecycleHandlerIfUnowned(
        id: UUID,
        prepare: @escaping () -> Bool,
        resume: @escaping () -> Void
    ) -> Bool {
        if documentLifecycleHandler?.id == id {
            return true
        }
        guard documentLifecycleHandler == nil else { return false }
        registerDocumentLifecycleHandler(id: id, prepare: prepare, resume: resume)
        return true
    }

    func unregisterDocumentLifecycleHandler(id: UUID) {
        guard documentLifecycleHandler?.id == id else { return }
        documentLifecycleHandler = nil
    }

    /// Adapter surfaceをactiveとして登録する。既存surfaceから別tokenへ切り替わる場合は、
    /// 旧surfaceに属するpending commandと取得済みsnapshotを先に失効させる。
    func activateEditorSurface(_ token: EditorSurfaceToken) {
        guard activeSurfaceToken != token else { return }
        if activeSurfaceToken != nil, let transactionID = pendingCommand?.id ?? selectionSnapshot?.id {
            rejectTransaction(id: transactionID)
        }
        committedTextCaptureHandler = nil
        activeSurfaceToken = token
        hasActiveEditorSurface = true
        hasNonEmptySelection = false
    }

    /// 既存surfaceが所有していないsessionだけをclaimする。SwiftUIの遅延updateで
    /// 旧Coordinatorが新surfaceからactive leaseを奪い返すことを防ぐ。
    @discardableResult
    func activateEditorSurfaceIfUnowned(_ token: EditorSurfaceToken) -> Bool {
        if activeSurfaceToken == token {
            return true
        }
        guard activeSurfaceToken == nil else { return false }
        committedTextCaptureHandler = nil
        activeSurfaceToken = token
        hasActiveEditorSurface = true
        hasNonEmptySelection = false
        return true
    }

    /// 同じCoordinator内の本文切替だけが、所有中のsurface tokenを更新できる。
    @discardableResult
    func replaceActiveEditorSurface(
        from currentToken: EditorSurfaceToken,
        with nextToken: EditorSurfaceToken
    ) -> Bool {
        guard activeSurfaceToken == currentToken else { return false }
        if let transactionID = pendingCommand?.id ?? selectionSnapshot?.id {
            rejectTransaction(id: transactionID)
        }
        committedTextCaptureHandler = nil
        activeSurfaceToken = nextToken
        hasActiveEditorSurface = true
        hasNonEmptySelection = false
        return true
    }

    /// Adapterの破棄時に、そのsurfaceへ拘束されたtransactionを失効させる。
    /// 新surfaceが既にactiveなら、遅れて届いた旧surfaceの破棄通知は無視する。
    func deactivateEditorSurface(_ token: EditorSurfaceToken) {
        guard activeSurfaceToken == token else { return }
        if let transactionID = pendingCommand?.id ?? selectionSnapshot?.id {
            rejectTransaction(id: transactionID)
        }
        committedTextCaptureHandler = nil
        activeSurfaceToken = nil
        hasActiveEditorSurface = false
        hasNonEmptySelection = false
    }

    /// 現在のsurface ownerだけが、同期全文取得handlerを登録・更新できる。
    @discardableResult
    func registerCommittedTextCaptureHandler(
        for surfaceToken: EditorSurfaceToken,
        capture: @escaping @MainActor () -> EditorCommittedTextCaptureResult
    ) -> Bool {
        guard activeSurfaceToken == surfaceToken else { return false }
        committedTextCaptureHandler = CommittedTextCaptureHandler(
            surfaceToken: surfaceToken,
            capture: capture
        )
        return true
    }

    /// commandが現在activeなsurfaceに属する場合だけ、Adapterでの処理を許可する。
    func canHandleCommand(id: UUID, on surfaceToken: EditorSurfaceToken) -> Bool {
        activeSurfaceToken == surfaceToken &&
            pendingCommand?.id == id &&
            pendingCommandSurfaceToken == surfaceToken
    }

    func receiveSelectionSnapshot(_ snapshot: EditorSelectionSnapshot, from surfaceToken: EditorSurfaceToken) {
        guard canHandleCommand(id: snapshot.id, on: surfaceToken) else { return }
        selectionSnapshot = snapshot
        selectionSnapshotSurfaceToken = surfaceToken
        pendingCommand = nil
        pendingCommandSurfaceToken = nil
    }

    func completeCommand(id: UUID, on surfaceToken: EditorSurfaceToken) {
        guard canHandleCommand(id: id, on: surfaceToken) else { return }
        pendingCommand = nil
        pendingCommandSurfaceToken = nil
        if selectionSnapshot?.id == id {
            selectionSnapshot = nil
            selectionSnapshotSurfaceToken = nil
        }
    }

    func rejectCommand(id: UUID, on surfaceToken: EditorSurfaceToken) {
        guard canHandleCommand(id: id, on: surfaceToken) else { return }
        rejectTransaction(id: id)
    }

    func updateSelectionAvailability(_ range: NSRange, from surfaceToken: EditorSurfaceToken) {
        guard activeSurfaceToken == surfaceToken else { return }
        hasNonEmptySelection = range.length > 0
    }

    private func rejectTransaction(id: UUID) {
        if pendingCommand?.id == id {
            pendingCommand = nil
            pendingCommandSurfaceToken = nil
        }
        if selectionSnapshot?.id == id {
            selectionSnapshot = nil
            selectionSnapshotSurfaceToken = nil
        }
        rejectedCommandID = id
    }
}
