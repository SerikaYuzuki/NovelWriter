import Foundation
import NovelCore
import NovelTextAnalysis
import Observation

/// 一時状態だけを保持する。本文変更と保存は各OSの既存gateに委ねる。
@MainActor
struct WorkReplacementHost {
    let scope: String
    let validate: () -> Bool
    let document: () -> NovelDocument
    let boundary: @MainActor (_ operation: @MainActor () async -> Bool) async -> Bool
    let snapshot: @MainActor () async -> Bool
    let apply: ([EpisodeTextChange]) -> Bool
}

@MainActor
@Observable
final class WorkSearchSession {
    var isPresented = false
    var query = ""
    var replacement = ""
    var excluded: [EpisodeID: Set<Int>] = [:]
    private(set) var results: [EpisodeTextMatches] = []
    private(set) var isSearching = false
    private(set) var isReplacing = false
    var message: String?
    private(set) var scope = ""
    private(set) var isStale = true
    @ObservationIgnored private var isVisible = true
    @ObservationIgnored private let search: @Sendable (String, NovelDocument) -> [EpisodeTextMatches]
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private var undoChanges: [EpisodeTextChange] = []
    private var undoScope = ""

    init(search: @escaping @Sendable (String, NovelDocument) -> [EpisodeTextMatches] = {
        WorkTextSearch.search(query: $0, in: $1)
    }, sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.search = search
        self.sleep = sleep
    }

    func setVisible(_ visible: Bool, document: NovelDocument, scope: String) {
        isVisible = visible
        if visible {
            if isStale || self.scope != scope {
                refresh(document: document, scope: scope)
            }
        } else {
            markStale()
        }
    }

    /// Retain the last results. Changes during typing never start a whole-work search.
    func markStale() {
        guard !isStale || isSearching || searchTask != nil else { return }
        searchTask?.cancel(); searchTask = nil; revision = UUID()
        if !isStale {
            isStale = true
        }
        if isSearching {
            isSearching = false
        }
    }

    var total: Int {
        results.reduce(0) { $0 + $1.matches.count }
    }

    var includedCount: Int {
        total - excluded.values.reduce(0) { $0 + $1.count }
    }

    var canUndo: Bool {
        !undoChanges.isEmpty && undoScope == scope
    }

    func invalidate() {
        searchTask?.cancel(); searchTask = nil
        revision = UUID()
        results = []; excluded = [:]; undoChanges = []
        isSearching = false
        isStale = true
        message = "作品またはアカウントが変わりました。検索画面を開き直してください。"
    }

    func refresh(document: NovelDocument, scope: String) {
        guard isVisible else { markStale(); return }
        searchTask?.cancel()
        revision = UUID()
        if self.scope != scope {
            self.scope = scope
            results = []
            undoChanges = []
            message = nil
        }
        isStale = true
        excluded = [:]
        isSearching = !query.isEmpty
        guard !query.isEmpty else { results = []; isStale = false; return }
        let query = query, revision = revision, search = search
        searchTask = Task { [weak self] in
            guard let sleep = self?.sleep else { return }
            do { try await sleep(.milliseconds(250)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { search(query, document) }
            let value = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.revision == revision, self.scope == scope else { return }
            searchTask = nil
            results = value
            isSearching = false
            isStale = false
        }
    }

    func included(_ match: WorkTextMatch, in result: EpisodeTextMatches) -> Bool {
        !(excluded[result.id] ?? []).contains(match.id)
    }

    func setIncluded(_ included: Bool, match: WorkTextMatch, in result: EpisodeTextMatches) {
        if included {
            excluded[result.id, default: []].remove(match.id)
        } else {
            excluded[result.id, default: []].insert(match.id)
        }
    }

    /// 検索結果は確認時点の値。検索後に一話でも変わっていたら全体を中止。
    @discardableResult
    func replace(using host: WorkReplacementHost) async -> Bool {
        guard !isReplacing, !isSearching, !isStale, host.scope == scope, host.validate() else { return false }
        message = nil
        let results = results, replacement = replacement, excluded = excluded
        isReplacing = true
        defer { isReplacing = false }
        let worker = Task.detached(priority: .userInitiated) {
            WorkTextSearch.replacements(results: results, replacement: replacement, excluded: excluded)
        }
        let changes = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard host.validate() else { return false }
        guard !changes.isEmpty else { message = "置換する変更がありません。"; return false }
        var applied = false
        let succeeded = await host.boundary {
            guard host.validate(), changes.allSatisfy({ $0.matches(host.document()) }) else {
                self.message = "検索後に本文が変わりました。もう一度検索してください。"; return false
            }
            guard await host.snapshot() else {
                self.message = "置換前の履歴を保存できませんでした。本文は置換していません。"; return false
            }
            guard host.validate(), changes.allSatisfy({ $0.matches(host.document()) }), host.apply(changes) else {
                self.message = "本文または作品が変わりました。もう一度検索してください。"; return false
            }
            applied = true
            self.undoChanges = changes
            self.undoScope = host.scope
            return true
        }
        guard host.validate() else { return false }
        if applied {
            message = succeeded ? "\(changes.reduce(0) { $0 + $1.count })件を置換しました。" : "置換しましたが保存できませんでした。保存を再試行してください。"
        } else if message == nil {
            message = "入力確定・保存を完了できなかったため、置換していません。"
        }
        return succeeded && applied
    }

    @discardableResult
    func undo(using host: WorkReplacementHost) async -> Bool {
        guard !isReplacing, canUndo, host.scope == undoScope, host.validate() else { return false }
        let inverse = undoChanges.map(\.inverse)
        isReplacing = true
        defer { isReplacing = false }
        var restored = 0, skipped = 0, applied = false
        let succeeded = await host.boundary {
            guard host.validate() else { return false }
            let current = host.document()
            let eligible = inverse.filter { $0.matches(current) }
            skipped = inverse.count - eligible.count
            guard !eligible.isEmpty else { self.undoChanges = []; return true }
            guard host.apply(eligible) else { return false }
            restored = eligible.count
            applied = true
            self.undoChanges = []
            return true
        }
        guard host.validate() else { return false }
        message = "\(restored)話を元に戻しました。"
        if skipped > 0 {
            message = "\(restored)話を元に戻しました。\(skipped)話は本文が変わったため戻していません。履歴（置換前のスナップショット）から復元できます。"
        }
        if !succeeded {
            message = applied ? "元に戻しましたが保存できませんでした。保存を再試行してください。" : "元に戻せませんでした。入力確定・保存を確認してください。"
        }
        return succeeded
    }
}
