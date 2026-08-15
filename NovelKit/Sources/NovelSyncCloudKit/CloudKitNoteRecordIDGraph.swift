import Foundation
import NovelSync

/// Development CloudKit may reject `CKQuery` (CKError 12 / 2015) until
/// `recordName` and `workID` are QUERYABLE. Known Note entities are still
/// addressable by record ID, so a work row plus its ordered children can be
/// fetched without a query.
enum CloudKitNoteRecordIDGraph {
    static func structureKeys(
        workID: SyncWorkID,
        work: NoteSyncWorkPayload
    ) -> [NoteSyncEntityKey] {
        work.chapterOrder.map { NoteSyncEntityKey(workID: workID, kind: .chapter, entityID: $0) }
            + work.characterOrder.map { NoteSyncEntityKey(workID: workID, kind: .character, entityID: $0) }
            + work.plotCardOrder.map { NoteSyncEntityKey(workID: workID, kind: .plotCard, entityID: $0) }
            + work.flagOrder.map { NoteSyncEntityKey(workID: workID, kind: .flag, entityID: $0) }
            + work.worldNoteOrder.map { NoteSyncEntityKey(workID: workID, kind: .worldNote, entityID: $0) }
    }

    static func episodeKeys(
        workID: SyncWorkID,
        chapters: [NoteSyncChapterPayload]
    ) -> [NoteSyncEntityKey] {
        chapters.flatMap { chapter in
            chapter.episodeOrder.map { NoteSyncEntityKey(workID: workID, kind: .episode, entityID: $0) }
        }
    }
}
