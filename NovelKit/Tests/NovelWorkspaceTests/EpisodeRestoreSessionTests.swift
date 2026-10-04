import Foundation
import NovelCore
import NovelTextAnalysis
@testable import NovelWorkspace
import Testing

@MainActor
struct EpisodeRestoreSessionTests {
    @Test func restoresOneEpisodeAfterCheckpointAndJournalAndInverseMatches() async {
        let fixture = EpisodeRestoreFixture()
        let session = EpisodeRestoreSession()
        let original = fixture.document
        let result = await session.restore(fixture.request, using: fixture.host, journal: fixture.journal)
        #expect(result)
        #expect(fixture.events == ["gate", "checkpoint", "journal", "apply", "save", "applied"])
        #expect(fixture.applied.count == 1)
        #expect(fixture.document.chapters[0].episodes[0].content == "old")
        #expect(fixture.document.chapters[0].episodes[1] == original.chapters[0].episodes[1])
        #expect(fixture.applied[0].inverse.matches(fixture.document))
        fixture.document.updateEpisodeContent(fixture.applied[0].before, for: fixture.applied[0].episodeID, in: fixture.applied[0].chapterID)
        #expect(fixture.document == original)
    }

    @Test func equalVersionStillVerifiesTheShownBodyInsideTheGate() async {
        let fixture = EpisodeRestoreFixture()
        let same = EpisodeRestoreRequest(scope: "scope", chapterID: fixture.document.chapters[0].id,
                                         episodeID: fixture.document.chapters[0].episodes[0].id, before: "current", after: "current")
        #expect(await EpisodeRestoreSession().restore(same, using: fixture.host, journal: fixture.journal))
        #expect(fixture.events == ["gate", "save"])
        fixture.document.chapters[0].episodes[0].content = "edited after confirmation"
        #expect(await EpisodeRestoreSession().restore(same, using: fixture.host, journal: fixture.journal) == false)
        #expect(fixture.applied.isEmpty)
    }

    @Test(arguments: ["checkpoint", "body", "scope", "journal", "conflict", "composition", "deleted"])
    func rejectsUnsafeOrFailedPreparationWithoutChangingManuscript(_ failure: String) async {
        let fixture = EpisodeRestoreFixture()
        let request = fixture.request
        switch failure {
        case "checkpoint": fixture.checkpointSucceeds = false
        case "body": fixture.document.chapters[0].episodes[0].content = "newer"
        case "scope": fixture.onCheckpoint = { fixture.valid = false }
        case "journal": fixture.journalSucceeds = false
        case "conflict", "composition": fixture.valid = false
        case "deleted": fixture.document.chapters[0].episodes.removeFirst()
        default: break
        }
        let original = fixture.document
        let result = await EpisodeRestoreSession().restore(request, using: fixture.host, journal: fixture.journal)
        #expect(!result)
        #expect(fixture.document == original)
        #expect(fixture.applied.isEmpty)
    }

    @Test func scopeOrBodyChangeDuringJournalRejectsAndSaveFailureKeepsPreparedEdit() async {
        let stale = EpisodeRestoreFixture()
        stale.onJournal = { stale.valid = false }
        #expect(await EpisodeRestoreSession().restore(stale.request, using: stale.host, journal: stale.journal) == false)
        #expect(stale.applied.isEmpty)
        #expect(stale.events.last == "rejected")
        let changed = EpisodeRestoreFixture()
        changed.onJournal = { changed.document.chapters[0].episodes[0].content = "newer" }
        #expect(await EpisodeRestoreSession().restore(changed.request, using: changed.host, journal: changed.journal) == false)
        #expect(changed.applied.isEmpty)
        let failedSave = EpisodeRestoreFixture()
        failedSave.saveSucceeds = false
        #expect(await EpisodeRestoreSession().restore(failedSave.request, using: failedSave.host, journal: failedSave.journal) == false)
        #expect(failedSave.applied.count == 1)
        #expect(failedSave.events.last == "save")
    }
}

@MainActor
private final class EpisodeRestoreFixture {
    var document = NovelDocument(title: "work", chapters: [Chapter(title: "chapter", episodes: [Episode(content: "current"), Episode(content: "other")])])
    var valid = true
    var checkpointSucceeds = true
    var journalSucceeds = true
    var saveSucceeds = true
    var onCheckpoint: () -> Void = {}
    var onJournal: () -> Void = {}
    var events: [String] = []
    var applied: [EpisodeTextChange] = []

    var request: EpisodeRestoreRequest {
        EpisodeRestoreRequest(scope: "scope", chapterID: document.chapters[0].id,
                              episodeID: document.chapters[0].episodes[0].id, before: "current", after: "old")
    }

    var journal: EpisodeRestoreJournal {
        EpisodeRestoreJournal(prepare: { _, _ in
            self.events.append("journal")
            self.onJournal()
            guard self.journalSucceeds else { throw CancellationError() }
            return UUID()
        }, finish: { _, state in self.events.append(state) })
    }

    var host: WorkReplacementHost {
        WorkReplacementHost(scope: "scope", validate: { self.valid }, document: { self.document },
                            boundary: { operation in
                                self.events.append("gate")
                                let applied = await operation()
                                if applied {
                                    self.events.append("save")
                                }
                                return applied && self.saveSucceeds
                            }, snapshot: {
                                self.events.append("checkpoint")
                                self.onCheckpoint()
                                return self.checkpointSucceeds
                            }, apply: { changes in
                                self.events.append("apply")
                                self.applied += changes
                                for change in changes {
                                    self.document.updateEpisodeContent(change.after, for: change.episodeID, in: change.chapterID)
                                }
                                return true
                            })
    }
}
