import NovelCore

extension IOSDocumentStore {
    func installDeviceSyncEpisodeContent(
        _ content: String,
        chapterID: ChapterID,
        episodeID: EpisodeID,
        advancesEditorGeneration: Bool
    ) {
        let previousContent = document.episode(episodeID)?.episode.content
        document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        if previousContent != content {
            registerDeviceSyncContentMutation(
                content,
                episodeID: episodeID,
                containsLocalEditIntent: false
            )
        }
        saveCoordinator.markDirty()
        if advancesEditorGeneration {
            advanceEditorContentGeneration()
        }
    }
}
