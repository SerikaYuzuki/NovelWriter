import Foundation
import NovelCore

extension IOSDocumentStore {
    func selectEpisodeAfterDeviceSyncDeparture(chapterID: ChapterID, episodeID: EpisodeID) async -> Bool {
        await performEditingDeparture {
            guard self.document.chapters.first(where: { $0.id == chapterID })?.episodes.contains(where: { $0.id == episodeID }) == true else { return false }
            self.selectChapter(chapterID)
            self.selectEpisode(episodeID)
            return true
        }
    }

    func addChapterAfterDeviceSyncDeparture() async -> Bool {
        await performEditingDeparture { self.addChapter(); return true }
    }

    func addEpisodeAfterDeviceSyncDeparture() async -> Bool {
        let chapterID = selectedChapterID
        return await performEditingDeparture {
            guard self.selectedChapterID == chapterID else { return false }
            self.addEpisode()
            return true
        }
    }

    func addEpisodeAfterDeviceSyncDeparture(to chapterID: ChapterID) async -> Bool {
        await performEditingDeparture {
            guard self.document.chapters.contains(where: { $0.id == chapterID }) else { return false }
            self.selectChapter(chapterID)
            self.addEpisode()
            return true
        }
    }

    func deleteEpisodesAfterDeviceSyncDeparture(at offsets: IndexSet, chapterID: ChapterID) async -> Bool {
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }),
              offsets.allSatisfy({ chapter.episodes.indices.contains($0) }) else { return false }
        let ids = Set(offsets.map { chapter.episodes[$0].id })
        return await performEditingDeparture {
            guard let current = self.document.chapters.first(where: { $0.id == chapterID }) else { return false }
            let remaining = IndexSet(current.episodes.indices.filter { ids.contains(current.episodes[$0].id) })
            if !remaining.isEmpty {
                self.deleteEpisodes(at: remaining, chapterID: chapterID)
            }
            return true
        }
    }

    func moveChaptersAfterDeviceSyncDeparture(fromOffsets: IndexSet, toOffset: Int) async -> Bool {
        let order = document.chapters.map(\.id)
        guard fromOffsets.allSatisfy({ order.indices.contains($0) }), (0 ... order.count).contains(toOffset) else { return false }
        return await performEditingDeparture {
            guard self.document.chapters.map(\.id) == order else { return false }
            self.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
            return true
        }
    }

    func moveEpisodesAfterDeviceSyncDeparture(
        in chapterID: ChapterID,
        fromOffsets: IndexSet,
        toOffset: Int
    ) async -> Bool {
        guard let order = document.chapters.first(where: { $0.id == chapterID })?.episodes.map(\.id),
              fromOffsets.allSatisfy({ order.indices.contains($0) }), (0 ... order.count).contains(toOffset) else { return false }
        return await performEditingDeparture {
            guard self.document.chapters.first(where: { $0.id == chapterID })?.episodes.map(\.id) == order else { return false }
            self.moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
            return true
        }
    }

    private func performEditingDeparture(_ operation: () -> Bool) async -> Bool {
        guard let session = currentDocumentSessionToken else { return false }
        let account = snapshotSyncV2AccountScope
        return await documentOperationGate.perform {
            guard self.currentDocumentSessionToken == session, self.snapshotSyncV2AccountScope == account,
                  !self.isDocumentTransitionInProgress, !self.syncV2AccountTransitionInProgress,
                  self.syncV2KeepBothPendingWorkID == nil else { return false }
            guard await self.prepareForEditorSurfaceDeparture(),
                  self.currentDocumentSessionToken == session, self.snapshotSyncV2AccountScope == account,
                  !self.isDocumentTransitionInProgress, !self.syncV2AccountTransitionInProgress,
                  self.syncV2KeepBothPendingWorkID == nil, !Task.isCancelled else { return false }
            return operation()
        }
    }
}
