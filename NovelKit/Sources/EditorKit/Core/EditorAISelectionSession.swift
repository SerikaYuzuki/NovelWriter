import Foundation

/// AI用の選択範囲を取得できない理由。
public enum EditorAISelectionUnavailableReason: Sendable, Equatable {
    case inactiveSurface
    case editorInactive
    case imeComposing
    case emptySelection
    case invalidSelection
}

/// 取得済みのAI用選択transactionを現在のEditorへ適用できない理由。
public enum EditorAISelectionStaleReason: Sendable, Equatable {
    case sessionChanged
    case inactiveSurface
    case surfaceChanged
    case editorInactive
    case imeComposing
    case contentChanged
    case selectionChanged
    case rangeChanged
    case invalidRange
    case sourceChanged
}

/// AI用選択transactionの取得・検査・置換で返す型付きerror。
public enum EditorAISelectionError: Error, Sendable, Equatable {
    case unavailable(EditorAISelectionUnavailableReason)
    case stale(EditorAISelectionStaleReason)
    case alreadyApplied
    case replacementRejected
}

/// EditorKitだけが生成できる、AI用の選択範囲transaction。
///
/// 呼び出し側へ公開する原稿データは、provider向けpromptの入力になる
/// ``selectedText`` だけである。取得元surface、本文／選択revision、UTF-16範囲、
/// exact source、one-shot apply leaseは内部capabilityへ封印し、呼び出し側から
/// 作成・差し替えできない。
public struct EditorAISelectionTransaction: Sendable, Identifiable {
    fileprivate let capability: EditorAISelectionCapability

    public var id: UUID {
        capability.id
    }

    public var selectedText: String {
        capability.exactText
    }

    init(capability: EditorAISelectionCapability) {
        self.capability = capability
    }
}

/// AI用選択transactionに封印するEditor内部identity。
///
/// transaction自体は非同期AI処理のあいだmemory上で保持できるよう`Sendable`とする。
/// apply leaseの唯一の可変状態はlock内で遷移し、Editorの検査・置換は別途
/// `EditorAISelectionSession`のMainActor境界で行う。
final class EditorAISelectionCapability: @unchecked Sendable {
    enum BeginApplyResult {
        case allowed
        case stale(EditorAISelectionStaleReason)
        case alreadyApplied
    }

    private enum State {
        case available
        case stale(EditorAISelectionStaleReason)
        case applyingOrApplied
    }

    let id: UUID
    let sessionIdentity: UUID
    let surfaceLeaseIdentity: UUID
    let surfaceToken: EditorSurfaceToken
    let contentRevision: UInt64
    let selectionRevision: UInt64
    let range: NSRange
    let exactText: String

    private let stateLock = NSLock()
    private var state = State.available

    init(
        id: UUID,
        sessionIdentity: UUID,
        surfaceLeaseIdentity: UUID,
        surfaceToken: EditorSurfaceToken,
        contentRevision: UInt64,
        selectionRevision: UInt64,
        range: NSRange,
        exactText: String
    ) {
        self.id = id
        self.sessionIdentity = sessionIdentity
        self.surfaceLeaseIdentity = surfaceLeaseIdentity
        self.surfaceToken = surfaceToken
        self.contentRevision = contentRevision
        self.selectionRevision = selectionRevision
        self.range = range
        self.exactText = exactText
    }

    func beginApply() -> BeginApplyResult {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch state {
        case .available:
            state = .applyingOrApplied
            return .allowed
        case let .stale(reason):
            return .stale(reason)
        case .applyingOrApplied:
            return .alreadyApplied
        }
    }

    var validationError: EditorAISelectionError? {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch state {
        case .available:
            return nil
        case let .stale(reason):
            return .stale(reason)
        case .applyingOrApplied:
            return .alreadyApplied
        }
    }

    @discardableResult
    func markStale(_ reason: EditorAISelectionStaleReason) -> EditorAISelectionError {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch state {
        case .available:
            state = .stale(reason)
            return .stale(reason)
        case let .stale(existingReason):
            return .stale(existingReason)
        case .applyingOrApplied:
            return .alreadyApplied
        }
    }
}

/// Platform Adapterが登録する、AppKit／UIKit非公開のAI選択操作境界。
struct EditorAISelectionSurfaceHandler {
    let ownerID: UUID
    let surfaceToken: EditorSurfaceToken
    let capture: (
        UUID,
        UUID,
        UUID,
        EditorSurfaceToken
    ) -> Result<EditorAISelectionCapability, EditorAISelectionError>
    let validate: (EditorAISelectionCapability) -> Result<Void, EditorAISelectionError>
    let replace: (EditorAISelectionCapability, String) -> Result<Void, EditorAISelectionError>
}

/// SwiftUI/App層とPlatform Adapterの間で、長時間のAI操作に使う選択範囲を拘束するsession。
///
/// 短時間のルビ・傍点操作に使う``EditorCommandSession``とは状態を共有しない。
/// Platform Adapterがactive surfaceの同期handlerを登録し、取得、stale検査、置換を
/// すべてMainActor上で行う。`NSTextView` / `UITextView`は公開APIへ現れない。
@MainActor
public final class EditorAISelectionSession {
    private struct ActiveSurface {
        var handler: EditorAISelectionSurfaceHandler
        let leaseIdentity: UUID
    }

    private let identity = UUID()
    private var activeSurface: ActiveSurface?

    public init() {}

    /// 現在のactive editorから、空でないIME確定済み選択範囲を取得する。
    public func captureSelection() -> Result<EditorAISelectionTransaction, EditorAISelectionError> {
        guard let activeSurface else {
            return .failure(.unavailable(.inactiveSurface))
        }
        let transactionID = UUID()
        return activeSurface.handler.capture(
            transactionID,
            identity,
            activeSurface.leaseIdentity,
            activeSurface.handler.surfaceToken
        )
        .map { EditorAISelectionTransaction(capability: $0) }
    }

    /// transactionが取得時と同じsurface・本文・選択を指しているかを検査する。
    ///
    /// 同じ文字列を本文内から再検索したり、現在選択へ読み替えたりしない。
    public func validate(
        _ transaction: EditorAISelectionTransaction
    ) -> Result<Void, EditorAISelectionError> {
        let capability = transaction.capability
        if let validationError = capability.validationError {
            return .failure(validationError)
        }
        guard capability.sessionIdentity == identity else {
            return .failure(capability.markStale(.sessionChanged))
        }
        guard let activeSurface else {
            return .failure(capability.markStale(.inactiveSurface))
        }
        let matchesSurface = activeSurface.leaseIdentity == capability.surfaceLeaseIdentity &&
            activeSurface.handler.surfaceToken == capability.surfaceToken
        guard matchesSurface else {
            return .failure(capability.markStale(.surfaceChanged))
        }
        let result = activeSurface.handler.validate(capability)
        if case let .failure(.stale(reason)) = result {
            return .failure(capability.markStale(reason))
        }
        return result
    }

    /// transactionが指すexact UTF-16範囲だけを、一度だけ置換する。
    ///
    /// one-shot leaseは最終検査より先に取得する。検査または置換が失敗しても同じ
    /// transactionを再利用せず、新しい選択取得からやり直す必要がある。
    public func replace(
        _ transaction: EditorAISelectionTransaction,
        with text: String
    ) -> Result<Void, EditorAISelectionError> {
        let capability = transaction.capability
        guard capability.sessionIdentity == identity else {
            return .failure(capability.markStale(.sessionChanged))
        }
        switch capability.beginApply() {
        case .allowed:
            break
        case let .stale(reason):
            return .failure(.stale(reason))
        case .alreadyApplied:
            return .failure(.alreadyApplied)
        }
        guard let activeSurface else {
            return .failure(.stale(.inactiveSurface))
        }
        let matchesSurface = activeSurface.leaseIdentity == capability.surfaceLeaseIdentity &&
            activeSurface.handler.surfaceToken == capability.surfaceToken
        guard matchesSurface else {
            return .failure(.stale(.surfaceChanged))
        }
        return activeSurface.handler.replace(capability, text)
    }

    /// 新しいCoordinator surfaceをactive ownerとして登録する。
    /// 既存ownerがあれば置き換え、古いtransactionはsurface token不一致でstaleになる。
    func activateEditorSurface(_ handler: EditorAISelectionSurfaceHandler) {
        activeSurface = ActiveSurface(handler: handler, leaseIdentity: UUID())
    }

    /// owner不在時だけ既存Coordinatorのsurfaceを復帰させる。
    /// SwiftUIの遅延updateで旧Coordinatorがactive leaseを奪い返すことを防ぐ。
    @discardableResult
    func claimEditorSurfaceIfUnowned(_ handler: EditorAISelectionSurfaceHandler) -> Bool {
        let matchesOwner = activeSurface?.handler.ownerID == handler.ownerID &&
            activeSurface?.handler.surfaceToken == handler.surfaceToken
        if matchesOwner {
            activeSurface?.handler = handler
            return true
        }
        guard activeSurface == nil else { return false }
        activeSurface = ActiveSurface(handler: handler, leaseIdentity: UUID())
        return true
    }

    /// 同じCoordinatorだけが、表示本文またはlifecycle世代の切替時にsurfaceを更新する。
    @discardableResult
    func replaceActiveEditorSurface(
        ownerID: UUID,
        from currentToken: EditorSurfaceToken,
        with handler: EditorAISelectionSurfaceHandler
    ) -> Bool {
        guard activeSurface?.handler.ownerID == ownerID,
              activeSurface?.handler.surfaceToken == currentToken,
              handler.ownerID == ownerID else { return false }
        activeSurface = ActiveSurface(handler: handler, leaseIdentity: UUID())
        return true
    }

    /// Adapterの破棄時に、ownerが一致するsurfaceだけを解放する。
    func deactivateEditorSurface(ownerID: UUID, token: EditorSurfaceToken) {
        guard activeSurface?.handler.ownerID == ownerID,
              activeSurface?.handler.surfaceToken == token else { return }
        activeSurface = nil
    }
}
