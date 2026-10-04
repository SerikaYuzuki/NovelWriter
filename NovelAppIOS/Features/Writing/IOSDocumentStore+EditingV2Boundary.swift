import Foundation
import NovelCore
import NovelWorkspace

extension IOSDocumentStore {
    func selectEpisodeAfterDeviceSyncDeparture(chapterID: ChapterID, episodeID: EpisodeID) async -> Bool {
        await performEditingDeparture {
            guard self.workspaceModel.document.chapters.first(where: { $0.id == chapterID })?.episodes.contains(where: { $0.id == episodeID }) == true else { return false }
            self.selectChapter(chapterID)
            self.selectEpisode(episodeID)
            return true
        }
    }

    func addChapterAfterDeviceSyncDeparture() async -> Bool {
        await performEditingDeparture { self.addChapter(); return true }
    }

    func addEpisodeAfterDeviceSyncDeparture() async -> Bool {
        let chapterID = workspaceModel.selectedChapterID
        return await performEditingDeparture {
            guard self.workspaceModel.selectedChapterID == chapterID else { return false }
            self.addEpisode()
            return true
        }
    }

    func addEpisodeAfterDeviceSyncDeparture(to chapterID: ChapterID) async -> Bool {
        await performEditingDeparture {
            guard self.workspaceModel.document.chapters.contains(where: { $0.id == chapterID }) else { return false }
            self.selectChapter(chapterID)
            self.addEpisode()
            return true
        }
    }

    func deleteEpisodesAfterDeviceSyncDeparture(at offsets: IndexSet, chapterID: ChapterID) async -> Bool {
        guard let chapter = workspaceModel.document.chapters.first(where: { $0.id == chapterID }),
              offsets.allSatisfy({ chapter.episodes.indices.contains($0) }) else { return false }
        let ids = Set(offsets.map { chapter.episodes[$0].id })
        return await performEditingDeparture {
            guard let current = self.workspaceModel.document.chapters.first(where: { $0.id == chapterID }) else { return false }
            let remaining = IndexSet(current.episodes.indices.filter { ids.contains(current.episodes[$0].id) })
            if !remaining.isEmpty {
                self.deleteEpisodes(at: remaining, chapterID: chapterID)
            }
            return true
        }
    }

    func moveChaptersAfterDeviceSyncDeparture(fromOffsets: IndexSet, toOffset: Int) async -> Bool {
        let order = workspaceModel.document.chapters.map(\.id)
        guard fromOffsets.allSatisfy({ order.indices.contains($0) }), (0 ... order.count).contains(toOffset) else { return false }
        return await performEditingDeparture {
            guard self.workspaceModel.document.chapters.map(\.id) == order else { return false }
            self.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
            return true
        }
    }

    func moveEpisodesAfterDeviceSyncDeparture(
        in chapterID: ChapterID,
        fromOffsets: IndexSet,
        toOffset: Int
    ) async -> Bool {
        guard let order = workspaceModel.document.chapters.first(where: { $0.id == chapterID })?.episodes.map(\.id),
              fromOffsets.allSatisfy({ order.indices.contains($0) }), (0 ... order.count).contains(toOffset) else { return false }
        return await performEditingDeparture {
            guard self.workspaceModel.document.chapters.first(where: { $0.id == chapterID })?.episodes.map(\.id) == order else { return false }
            self.moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
            return true
        }
    }

    private func performEditingDeparture(_ operation: @MainActor () -> Bool) async -> Bool {
        await EpisodeTransition(host: self).perform(operation: operation)
    }
}
