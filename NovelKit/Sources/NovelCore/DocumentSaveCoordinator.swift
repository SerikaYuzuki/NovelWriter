import Foundation

/// 保存要求を revision ベースで直列化する調整役(docs/DESIGN.md 6.4, D-017)。
///
/// `NovelCore` は他モジュールに依存してはならない(docs/DESIGN.md 9.1)ため、
/// 実際の保存処理(`.novelpkg` への書き込みなど)は `saveOperation` としてクロージャ
/// 注入する。保存対象の最新状態(本文モデルと保存先URL)も同様に `currentState`
/// としてクロージャ注入し、呼び出し側(例: App層の `AppState`)が持つ最新の状態を
/// 都度取得できるようにする。
///
/// 設計上の要点(check-then-act 競合の排除):
///
/// 元の実装では「実行中の保存タスクを await → 呼び出し元が `activeSaveTask = nil`
/// する」という2ステップの後始末をしていたため、タスク完了後・nil化前の
/// suspension の隙間で別の呼び出しが割り込むと、完了済みタスクの古い結果を
/// そのまま返してしまい、その間に増えた dirty な revision を保存し損ねる恐れが
/// あった。
///
/// この型では「保存ループを回している呼び出し(owner)」と「その完了を待つだけの
/// 呼び出し(waiter)」を `isSaving` フラグと `waiters` 配列で管理する。
/// `isSaving` のチェックとセット、ループ終了後の `isSaving = false` と
/// waiter への通知は、どちらも `await` を挟まない一続きの同期処理として書かれて
/// いるため、他の呼び出しがその間に割り込む余地がない(MainActor は直列実行の
/// ため、suspension point の無い区間はどのタスクからも横入りされない)。
/// また owner は「保存が必要な revision が無くなるまで」ループし続けるため、
/// 保存中に新たに `markDirty()` された分もそのまま同じ呼び出しの中で保存される。
@MainActor
public final class DocumentSaveCoordinator {
    /// 現在保存すべき本文モデルと保存先URLを取得する。
    /// 取得できない(例: 呼び出し元が既に解放されている)場合は `nil`。
    public typealias CurrentStateProvider = () -> (document: NovelDocument, url: URL)?

    /// 実際の保存処理。`DocumentRepository.save(_:to:)` と同じ形。
    public typealias SaveOperation = (NovelDocument, URL) async throws -> Void

    private let debounceNanoseconds: UInt64
    private let currentState: CurrentStateProvider
    private let saveOperation: SaveOperation

    private var saveRevision = 0
    private var savedRevision = 0
    private var isSaving = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var debouncedSaveTask: Task<Void, Never>?

    /// - Parameters:
    ///   - debounceNanoseconds: `scheduleDebouncedSave()` が実際に保存を実行するまでの遅延。
    ///   - currentState: 保存すべき最新の本文モデルと保存先URLを返すクロージャ。
    ///   - saveOperation: 実際の保存処理(例: `repository.save`)。
    public init(
        debounceNanoseconds: UInt64,
        currentState: @escaping CurrentStateProvider,
        saveOperation: @escaping SaveOperation
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.currentState = currentState
        self.saveOperation = saveOperation
    }

    /// 保存対象を dirty としてマークする。次の `saveNow()` / デバウンス保存の対象になる。
    public func markDirty() {
        saveRevision += 1
    }

    /// `debounceNanoseconds` 後に `saveNow()` を実行するようスケジュールする。
    /// 既に保留中のデバウンスがあればキャンセルして再スケジュールする。
    public func scheduleDebouncedSave() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await saveNow()
        }
    }

    /// 保留中のデバウンス保存をキャンセルし、dirty な revision が無くなるまで保存してから
    /// 結果を返す。
    ///
    /// 既に別の呼び出しが保存ループを回している(`isSaving == true`)場合は、その
    /// ループが「呼び出し時点までの dirty をすべて保存し終える」まで待ってから、
    /// その結果をそのまま返す(古い完了済みタスクの結果を誤って返すことはない)。
    @discardableResult
    public func saveNow() async -> Bool {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil

        if isSaving {
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        guard savedRevision < saveRevision else {
            return true
        }

        isSaving = true
        var succeeded = true

        while savedRevision < saveRevision {
            let revision = saveRevision
            guard let (document, url) = currentState() else {
                // 呼び出し元が既に解放されているなど、保存対象を取得できない。
                // これ以上ループしても仕方ないので抜ける。
                break
            }

            do {
                try await saveOperation(document, url)
                savedRevision = max(savedRevision, revision)
            } catch {
                succeeded = false
                break
            }
        }

        // ここから return までの間に `await` は無い。他の呼び出しがこの間に
        // 割り込んで `isSaving` や `waiters` を観測することはできない。
        isSaving = false
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume(returning: succeeded)
        }

        return succeeded
    }
}
