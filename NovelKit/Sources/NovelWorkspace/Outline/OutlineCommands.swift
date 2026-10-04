import Foundation
import NovelCore

@MainActor
public protocol WorkspaceOutlineHost: WorkspaceHost {
    var selectedChapterID: ChapterID? { get set }
    var selectedEpisodeID: EpisodeID? { get set }
    func outlineSelectionChanged()
    func outlineChapterRemoved(_ id: ChapterID)
    func markOutlineChanged()
}

public enum OutlineSelectionRepair: Sendable {
    case adjacent
    case first
}

/// Array order is authoritative. Title defaults and deletion repair retain platform policy.
@MainActor
public struct OutlineCommands {
    private let host: any WorkspaceOutlineHost
    private let policy: WorkspaceSavePolicy?
    private let preparedTransition: Bool

    public init(host: any WorkspaceOutlineHost, policy: WorkspaceSavePolicy? = nil, preparedTransition: Bool = false) {
        self.host = host
        self.policy = policy
        self.preparedTransition = preparedTransition
    }

    private func permits(_ session: WorkspaceSessionToken? = nil, account: WorkspaceAccountScope? = nil) -> Bool {
        (host.permitsLocalMutation || preparedTransition)
            && (session == nil || host.operationContext.session == session)
            && (account == nil || host.operationContext.account == account)
    }

    private func changed() {
        if let policy {
            host.markChanged(policy: policy)
        } else {
            host.markOutlineChanged()
        }
    }

    public func setSelection(chapterID: ChapterID?, episodeID: EpisodeID?) {
        host.selectedChapterID = chapterID
        host.selectedEpisodeID = episodeID
        host.outlineSelectionChanged()
    }

    @discardableResult
    public func selectChapter(_ id: ChapterID?, preservingEpisode: Bool = false) -> Bool {
        guard permits() else { return false }
        let episodes = host.document.chapters.first(where: { $0.id == id })?.episodes ?? []
        let episode = preservingEpisode && episodes.contains(where: { $0.id == host.selectedEpisodeID })
            ? host.selectedEpisodeID : episodes.first?.id
        setSelection(chapterID: id, episodeID: episode)
        return true
    }

    @discardableResult
    public func selectEpisode(_ id: EpisodeID?, in chapterID: ChapterID, validate: Bool = true) -> Bool {
        guard permits() else { return false }
        if validate {
            guard let chapter = host.document.chapters.first(where: { $0.id == chapterID }),
                  id == nil ? chapter.episodes.isEmpty : chapter.episodes.contains(where: { $0.id == id }) else { return false }
        }
        setSelection(chapterID: chapterID, episodeID: id)
        return true
    }

    @discardableResult
    public func addChapter(includingFirstEpisode: Bool = false) -> Bool {
        guard permits() else { return false }
        let id = host.document.addChapter(title: "第\(host.document.chapters.count + 1)章")
        let episodeID = includingFirstEpisode ? host.document.addEpisode(to: id) : nil
        setSelection(chapterID: id, episodeID: episodeID)
        changed()
        return true
    }

    @discardableResult
    public func addEpisode(to chapterID: ChapterID?, title: String? = nil, firstTitle: String? = nil) -> Bool {
        guard permits(), let chapterID,
              let chapter = host.document.chapters.first(where: { $0.id == chapterID }) else { return false }
        let resolved = title ?? (chapter.episodes.isEmpty ? firstTitle : nil) ?? "第\(chapter.episodes.count + 1)話"
        guard let id = host.document.addEpisode(to: chapterID, title: resolved) else { return false }
        setSelection(chapterID: chapterID, episodeID: id)
        changed()
        return true
    }

    public func renameChapter(_ title: String, id: ChapterID) {
        guard permits(), let chapter = host.document.chapters.first(where: { $0.id == id }), chapter.title != title else { return }
        host.document.updateTitle(title, for: id)
        changed()
    }

    public func renameEpisode(_ title: String, id: EpisodeID, in chapterID: ChapterID,
                              expectedSession: WorkspaceSessionToken? = nil, expectedAccount: WorkspaceAccountScope? = nil) {
        guard permits(expectedSession, account: expectedAccount),
              let episode = host.document.chapters.first(where: { $0.id == chapterID })?.episodes.first(where: { $0.id == id }),
              episode.title != title else { return }
        host.document.updateEpisodeTitle(title, for: id, in: chapterID)
        changed()
    }

    @discardableResult
    public func deleteChapter(_ id: ChapterID, expectedSession: WorkspaceSessionToken? = nil) -> Bool {
        guard permits(expectedSession), host.document.chapters.count > 1,
              let index = host.document.chapters.firstIndex(where: { $0.id == id }),
              host.document.removeChapter(id: id) != nil else { return false }
        if host.selectedChapterID == id {
            let chapter = host.document.chapters[min(index, host.document.chapters.count - 1)]
            setSelection(chapterID: chapter.id, episodeID: chapter.episodes.first?.id)
        }
        host.outlineChapterRemoved(id)
        changed()
        return true
    }

    @discardableResult
    public func deleteEpisodes(_ ids: Set<EpisodeID>, in chapterID: ChapterID, repair: OutlineSelectionRepair = .adjacent,
                               expectedSession: WorkspaceSessionToken? = nil) -> Bool {
        guard permits(expectedSession), let chapter = host.document.chapters.first(where: { $0.id == chapterID }) else { return false }
        let removed = chapter.episodes.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return false }
        let selectedIndex = chapter.episodes.firstIndex(where: { $0.id == host.selectedEpisodeID }) ?? 0
        for episode in removed {
            _ = host.document.removeEpisode(id: episode.id, from: chapterID)
        }
        if let selected = host.selectedEpisodeID, ids.contains(selected) {
            let remaining = host.document.chapters.first(where: { $0.id == chapterID })?.episodes ?? []
            let index = repair == .first ? 0 : min(selectedIndex, max(remaining.count - 1, 0))
            setSelection(chapterID: chapterID, episodeID: remaining.indices.contains(index) ? remaining[index].id : nil)
        }
        changed()
        return true
    }

    public func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        guard permits(), fromOffsets.allSatisfy({ host.document.chapters.indices.contains($0) }),
              (0 ... host.document.chapters.count).contains(toOffset) else { return }
        host.document.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        changed()
    }

    public func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        guard permits(), let chapter = host.document.chapters.first(where: { $0.id == chapterID }),
              fromOffsets.allSatisfy({ chapter.episodes.indices.contains($0) }), (0 ... chapter.episodes.count).contains(toOffset) else { return }
        host.document.moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
        changed()
    }

    @discardableResult
    public func moveEpisode(_ id: EpisodeID, from source: ChapterID, to destination: ChapterID, before target: EpisodeID? = nil) -> Bool {
        guard permits(), host.document.moveEpisode(id: id, from: source, to: destination, before: target) else { return false }
        if host.selectedEpisodeID == id {
            setSelection(chapterID: destination, episodeID: id)
        }
        changed()
        return true
    }
}
