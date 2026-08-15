import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit note record ID graph")
struct CloudKitNoteRecordIDGraphTests {
    @Test("work payload plus chapters collect child record IDs")
    func structureAndEpisodeKeysFollowOrders() {
        let workID = SyncWorkID()
        let chapterID = WorkStableID(rawValue: UUID())
        let episodeID = WorkStableID(rawValue: UUID())
        let characterID = WorkStableID(rawValue: UUID())
        let work = NoteSyncWorkPayload(
            documentID: WorkStableID(rawValue: workID.rawValue),
            title: "graph",
            synopsis: "",
            chapterOrder: [chapterID],
            characterOrder: [characterID],
            plotCardOrder: [],
            flagOrder: [],
            worldNoteOrder: []
        )
        let chapter = NoteSyncChapterPayload(title: "章", episodeOrder: [episodeID])

        let structure = CloudKitNoteRecordIDGraph.structureKeys(workID: workID, work: work)
        #expect(
            structure.contains(
                NoteSyncEntityKey(workID: workID, kind: .chapter, entityID: chapterID)
            )
        )
        #expect(
            structure.contains(
                NoteSyncEntityKey(workID: workID, kind: .character, entityID: characterID)
            )
        )
        #expect(!structure.contains { $0.kind == .episode })

        let episodes = CloudKitNoteRecordIDGraph.episodeKeys(
            workID: workID,
            chapters: [chapter]
        )
        #expect(
            episodes == [
                NoteSyncEntityKey(workID: workID, kind: .episode, entityID: episodeID)
            ]
        )
    }
}
