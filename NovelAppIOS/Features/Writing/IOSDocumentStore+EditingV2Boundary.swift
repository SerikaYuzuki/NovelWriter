import Foundation
import NovelCore

extension IOSDocumentStore {
    func selectEpisodeAfterDeviceSyncDeparture(chapterID: ChapterID, episodeID: EpisodeID) async -> Bool {
        guard await prepareForEditorSurfaceDeparture() else { return false }
        selectChapter(chapterID)
        selectEpisode(episodeID)
        return true
    }

    func addChapterAfterDeviceSyncDeparture() async -> Bool {
        guard await prepareForEditorSurfaceDeparture() else { return false }
        addChapter()
        return true
    }

    func addEpisodeAfterDeviceSyncDeparture() async -> Bool {
        guard await prepareForEditorSurfaceDeparture() else { return false }
        addEpisode()
        return true
    }

    func deleteEpisodesAfterDeviceSyncDeparture(at offsets: IndexSet, chapterID: ChapterID) async -> Bool {
        guard await prepareForEditorSurfaceDeparture() else { return false }
        deleteEpisodes(at: offsets, chapterID: chapterID)
        return true
    }

    func moveChaptersAfterDeviceSyncDeparture(fromOffsets: IndexSet, toOffset: Int) async -> Bool {
        guard await prepareForEditorSurfaceDeparture() else { return false }
        moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        return true
    }

    func moveEpisodesAfterDeviceSyncDeparture(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) async -> Bool {
        guard await prepareForEditorSurfaceDeparture() else { return false }
        moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
        return true
    }
}
