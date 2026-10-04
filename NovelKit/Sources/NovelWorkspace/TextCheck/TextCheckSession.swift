import Foundation
import NovelCore
import NovelTextAnalysis
import Observation

/// 作品ごとの無視だけをUserDefaultsへ保存する。解析結果・設定は端末内の一時状態。
@MainActor
@Observable
public final class TextCheckSession {
    public var isPresented = false
    public var allWork = true {
        didSet {
            if oldValue != allWork {
                invalidate()
            }
        }
    }

    public var excludeDialogue = false {
        didSet {
            if oldValue != excludeDialogue {
                invalidate()
            }
        }
    }

    public private(set) var isChecking = false
    public private(set) var hasChecked = false
    public private(set) var scope = ""
    public private(set) var ignored: [String: String] = [:]
    public private(set) var results: [TextCheckIssue] = []
    public var message: String?
    private var workID: UUID?
    private var snapshot: NovelDocument?
    private var revision = UUID()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var worker: Task<[TextCheckIssue], Never>?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private var ignoredKey: String? {
        workID.map { "fuminiwa.textcheck.ignored.\($0.uuidString.lowercased())" }
    }

    public var visibleIssues: [TextCheckIssue] {
        results.compactMap { issue in
            guard ignored[issue.id] == nil else { return nil }
            let occurrences = issue.occurrences.filter { ignored[Self.occurrenceKey(issue, $0)] == nil }
            guard !occurrences.isEmpty else { return nil }
            return TextCheckIssue(id: issue.id, rule: issue.rule, title: issue.title,
                                  variants: issue.variants, occurrences: occurrences)
        }
    }

    public var isEmpty: Bool {
        visibleIssues.isEmpty
    }

    public var orderedEpisodeIDs: [EpisodeID] {
        snapshot?.chapters.flatMap { $0.episodes.map(\.id) } ?? []
    }

    public var count: Int {
        visibleIssues.reduce(0) { $0 + $1.occurrences.count }
    }

    public func bind(workID: UUID?, scope: String) {
        guard self.workID != workID || self.scope != scope else { return }
        invalidate()
        self.workID = workID; self.scope = scope
        ignored = ignoredKey.flatMap { defaults.dictionary(forKey: $0) as? [String: String] } ?? [:]
    }

    public func synchronize(document: NovelDocument, workID: UUID?, scope: String) {
        bind(workID: workID, scope: scope)
        if let snapshot, snapshot.chapters != document.chapters || snapshot.characters != document.characters {
            invalidate()
            message = "本文または人物設定が変わりました。「チェック」を押してください。"
        }
    }

    public func invalidate() {
        worker?.cancel(); worker = nil; revision = UUID()
        results = []; snapshot = nil; isChecking = false; hasChecked = false; message = nil
    }

    public func check(document: NovelDocument, workID: UUID, scope: String, episodeID: EpisodeID?,
                      checker: TextChecker = TextChecker(), validate: @MainActor () -> Bool) async {
        bind(workID: workID, scope: scope)
        invalidate()
        snapshot = document
        isChecking = true
        let revision = revision
        let options = TextCheckOptions(excludeDialogue: excludeDialogue)
        let worker = Task.detached(priority: .userInitiated) { checker.check(document, episodeID: episodeID, options: options) }
        self.worker = worker
        let value = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard self.revision == revision else { return }
        self.worker = nil; isChecking = false
        guard !Task.isCancelled, self.scope == scope, self.workID == workID, validate() else { invalidate(); return }
        results = value; hasChecked = true
    }

    public func ignore(_ issue: TextCheckIssue, occurrence: TextCheckOccurrence? = nil) {
        guard workID != nil, results.contains(where: { $0.id == issue.id }) else { return }
        let key = occurrence.map { Self.occurrenceKey(issue, $0) } ?? issue.id
        ignored[key] = occurrence.map { "\(issue.title) · \($0.result.episodeTitle) · \($0.match.context)" } ?? issue.title
        persistIgnored()
    }

    public func restoreIgnored(_ key: String) {
        ignored.removeValue(forKey: key); persistIgnored()
    }

    private func persistIgnored() {
        if let ignoredKey {
            defaults.set(ignored, forKey: ignoredKey)
        }
    }

    private static func occurrenceKey(_ issue: TextCheckIssue, _ occurrence: TextCheckOccurrence) -> String {
        "\(issue.id):\(occurrence.id):\(occurrence.match.context)"
    }

    public func prefillReplacement(_ issue: TextCheckIssue, search: WorkSearchSession, expectedScope: String) -> Bool {
        guard scope == expectedScope, hasChecked, visibleIssues.contains(where: { $0.id == issue.id }),
              let prefill = issue.replacement else { return false }
        search.query = prefill.query; search.replacement = prefill.replacement
        return true
    }
}
