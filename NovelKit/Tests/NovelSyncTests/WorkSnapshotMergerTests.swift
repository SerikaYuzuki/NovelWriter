// One suite mirrors the complete stable-ID merge contract.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable type_body_length
import Foundation
import NovelCore
import NovelSync
import Testing

@Suite("Whole-work stable-ID merger")
struct WorkSnapshotMergerTests {
    @Test("unrelated additions coexist and delete-versus-unchanged deletes")
    func additiveEntitiesAndCleanDelete() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            document.characters.removeAll { $0.id == WorkTestValues.character1 }
            document.characters.append(Character(name: "local add"))
        }
        let remote = try WorkTestValues.snapshot { document in
            document.worldNotes.append(WorldNote(title: "remote add", content: "remote body"))
        }

        guard case let .merged(merged) = try WorkSnapshotMerger.merge(
            base: base,
            local: local,
            remote: remote
        ) else {
            Issue.record("independent entity edits unexpectedly conflicted")
            return
        }
        let document = try merged.materializedDocument()
        #expect(!document.characters.contains { $0.id == WorkTestValues.character1 })
        #expect(document.characters.contains { $0.name == "local add" })
        #expect(document.worldNotes.contains { $0.title == "remote add" })
    }

    @Test("portable text merger combines disjoint body and world-note edits")
    func disjointTextMerges() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "ONE\ntwo\nthree"
            document.worldNotes[0].content = "LOCAL\nworld"
        }
        let remote = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "one\ntwo\nTHREE"
            document.worldNotes[0].content = "世界観本文\nREMOTE"
        }

        guard case let .merged(merged) = try WorkSnapshotMerger.merge(
            base: base,
            local: local,
            remote: remote
        ) else {
            Issue.record("disjoint text edits unexpectedly conflicted")
            return
        }
        let document = try merged.materializedDocument()
        #expect(document.chapters[0].episodes[0].content == "ONE\ntwo\nTHREE")
        #expect(document.worldNotes[0].content.contains("LOCAL"))
        #expect(document.worldNotes[0].content.contains("REMOTE"))
    }

    @Test("same scalar field keeps local, remote, and proposed evidence")
    func sameScalarConflict() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { $0.title = "local title" }
        let remote = try WorkTestValues.snapshot { $0.title = "remote title" }

        guard case let .conflicted(proposed, conflicts) = try WorkSnapshotMerger.merge(
            base: base,
            local: local,
            remote: remote
        ) else {
            Issue.record("same-field edit did not require review")
            return
        }
        let title = try #require(conflicts.first { $0.path == "document.title" })
        #expect(title.reason == .sameFieldChanged)
        #expect(title.localValue == "local title")
        #expect(title.remoteValue == "remote title")
        #expect(proposed.title == "local title")
    }

    @Test("independent episode move and content edit merge automatically")
    func moveAndContentEdit() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            let episode = document.chapters[0].episodes.removeFirst()
            document.chapters[1].episodes.append(episode)
        }
        let remote = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes[0].content = "remote body edit"
        }

        guard case let .merged(merged) = try WorkSnapshotMerger.merge(
            base: base,
            local: local,
            remote: remote
        ) else {
            Issue.record("independent move and content edit unexpectedly conflicted")
            return
        }
        let document = try merged.materializedDocument()
        #expect(!document.chapters[0].episodes.contains { $0.id == WorkTestValues.episode1 })
        #expect(document.chapters[1].episodes.first { $0.id == WorkTestValues.episode1 }?.content == "remote body edit")
    }

    @Test("delete versus move and two different moves require explicit review")
    func deleteAndDualMoveConflicts() throws {
        let base = try WorkTestValues.snapshot()
        let deleted = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes.removeAll { $0.id == WorkTestValues.episode1 }
        }
        let movedToSecond = try WorkTestValues.snapshot { document in
            let episode = document.chapters[0].episodes.removeFirst()
            document.chapters[1].episodes.append(episode)
        }
        guard case let .conflicted(proposedDelete, deleteConflicts) = try WorkSnapshotMerger.merge(
            base: base,
            local: deleted,
            remote: movedToSecond
        ) else {
            Issue.record("delete-versus-move was silently resolved")
            return
        }
        #expect(deleteConflicts.contains { $0.entityKind == .episode && $0.reason == .deleteVersusEdit })
        #expect(try proposedDelete.materializedDocument().chapters[1].episodes.contains {
            $0.id == WorkTestValues.episode1
        })

        let movedToThird = try WorkTestValues.snapshot { document in
            let episode = document.chapters[0].episodes.removeFirst()
            document.chapters[2].episodes.append(episode)
        }
        guard case let .conflicted(_, moveConflicts) = try WorkSnapshotMerger.merge(
            base: base,
            local: movedToSecond,
            remote: movedToThird
        ) else {
            Issue.record("two different moves were silently resolved")
            return
        }
        #expect(moveConflicts.contains {
            $0.entityKind == .episode && $0.field == "chapterID" && $0.reason == .sameFieldChanged
        })
    }

    @Test("chapter delete versus plot and flag reference edits keeps review evidence")
    func chapterDeleteReferenceConflict() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            _ = document.removeChapter(id: WorkTestValues.chapter1)
        }
        let remote = try WorkTestValues.snapshot { document in
            document.plotCards[0].memo = "remote plot edit"
            document.flags[0].note = "remote flag edit"
        }

        guard case let .conflicted(proposed, conflicts) = try WorkSnapshotMerger.merge(
            base: base,
            local: local,
            remote: remote
        ) else {
            Issue.record("chapter delete-versus-reference edit was silently detached")
            return
        }
        #expect(conflicts.contains { $0.entityKind == .chapter && $0.reason == .deleteVersusEdit })
        let document = try proposed.materializedDocument()
        #expect(document.chapters.contains { $0.id == WorkTestValues.chapter1 })
        #expect(document.plotCards[0].chapterID == WorkTestValues.chapter1)
        #expect(document.flags[0].plantedChapterID == WorkTestValues.chapter1)
    }

    @Test("different concurrent reorderings require choice and proposed order stays valid")
    func reorderConflict() throws {
        let base = try WorkTestValues.snapshot()
        let local = try WorkTestValues.snapshot { document in
            document.characters = [document.characters[1], document.characters[0], document.characters[2]]
        }
        let remote = try WorkTestValues.snapshot { document in
            document.characters = [document.characters[0], document.characters[2], document.characters[1]]
        }

        guard case let .conflicted(proposed, conflicts) = try WorkSnapshotMerger.merge(
            base: base,
            local: local,
            remote: remote
        ) else {
            Issue.record("two reorderings were silently resolved")
            return
        }
        #expect(conflicts.contains { $0.reason == .bothOrdersChanged })
        #expect(try proposed.materializedDocument().characters.map(\.id) == [
            WorkTestValues.character2, WorkTestValues.character1, WorkTestValues.character3
        ])
    }

    @Test("one-sided chapter, episode, and character insertions retain their anchors")
    func oneSidedInsertionAnchors() throws {
        let base = try WorkTestValues.snapshot()
        let remote = try WorkTestValues.snapshot { $0.title = "remote title edit" }

        let chapterID = try ChapterID(rawValue: #require(UUID(uuidString: "10000000-0000-0000-0000-000000000010")))
        let chapterLocal = try WorkTestValues.snapshot { document in
            document.chapters.insert(Chapter(id: chapterID, title: "挿入章", episodes: []), at: 1)
        }
        guard case let .merged(chapterMerged) = try WorkSnapshotMerger.merge(
            base: base,
            local: chapterLocal,
            remote: remote
        ) else {
            Issue.record("one-sided chapter insertion unexpectedly conflicted")
            return
        }
        #expect(try chapterMerged.materializedDocument().chapters.map(\.id) == [
            WorkTestValues.chapter1, chapterID, WorkTestValues.chapter2, WorkTestValues.chapter3
        ])

        let episodeID = try EpisodeID(rawValue: #require(UUID(uuidString: "20000000-0000-0000-0000-000000000010")))
        let episodeLocal = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes.insert(
                Episode(id: episodeID, title: "挿入話", content: "本文", memo: ""),
                at: 0
            )
        }
        guard case let .merged(episodeMerged) = try WorkSnapshotMerger.merge(
            base: base,
            local: episodeLocal,
            remote: remote
        ) else {
            Issue.record("one-sided episode insertion unexpectedly conflicted")
            return
        }
        #expect(try episodeMerged.materializedDocument().chapters[0].episodes.map(\.id) == [
            episodeID, WorkTestValues.episode1, WorkTestValues.episode2
        ])

        let characterID = try CharacterID(rawValue: #require(UUID(uuidString: "30000000-0000-0000-0000-000000000010")))
        let characterLocal = try WorkTestValues.snapshot { document in
            document.characters.insert(Character(id: characterID, name: "挿入人物"), at: 1)
        }
        guard case let .merged(characterMerged) = try WorkSnapshotMerger.merge(
            base: base,
            local: characterLocal,
            remote: remote
        ) else {
            Issue.record("one-sided character insertion unexpectedly conflicted")
            return
        }
        #expect(try characterMerged.materializedDocument().characters.map(\.id) == [
            WorkTestValues.character1, characterID, WorkTestValues.character2, WorkTestValues.character3
        ])
    }

    @Test("concurrent insertions are deterministic and incompatible anchors require review")
    func concurrentInsertionAnchors() throws {
        let base = try WorkTestValues.snapshot()
        let firstID = try CharacterID(rawValue: #require(UUID(uuidString: "30000000-0000-0000-0000-000000000010")))
        let secondID = try CharacterID(rawValue: #require(UUID(uuidString: "30000000-0000-0000-0000-000000000011")))
        let local = try WorkTestValues.snapshot { document in
            document.characters.insert(Character(id: firstID, name: "local add"), at: 1)
        }
        let remote = try WorkTestValues.snapshot { document in
            document.characters.insert(Character(id: secondID, name: "remote add"), at: 1)
        }
        guard case let .merged(merged) = try WorkSnapshotMerger.merge(
            base: base,
            local: local,
            remote: remote
        ) else {
            Issue.record("compatible concurrent insertions unexpectedly conflicted")
            return
        }
        #expect(try merged.materializedDocument().characters.map(\.id) == [
            WorkTestValues.character1,
            firstID,
            secondID,
            WorkTestValues.character2,
            WorkTestValues.character3
        ])

        let sharedID = try CharacterID(rawValue: #require(UUID(uuidString: "30000000-0000-0000-0000-000000000012")))
        let localAnchor = try WorkTestValues.snapshot { document in
            document.characters.insert(Character(id: sharedID, name: "shared add"), at: 1)
        }
        let remoteAnchor = try WorkTestValues.snapshot { document in
            document.characters.append(Character(id: sharedID, name: "shared add"))
        }
        guard case let .conflicted(proposed, conflicts) = try WorkSnapshotMerger.merge(
            base: base,
            local: localAnchor,
            remote: remoteAnchor
        ) else {
            Issue.record("incompatible insertion anchors were silently resolved")
            return
        }
        #expect(conflicts.contains { $0.path == "characters.$order" && $0.reason == .bothOrdersChanged })
        #expect(try proposed.materializedDocument().characters.map(\.id) == [
            WorkTestValues.character1,
            sharedID,
            WorkTestValues.character2,
            WorkTestValues.character3
        ])
    }

    @Test("document identity cannot be merged")
    func documentIdentityGuard() throws {
        let base = try WorkTestValues.snapshot()
        var other = WorkTestValues.fullDocument()
        other.id = UUID()
        let remote = try WorkSnapshot(document: other)
        #expect(throws: WorkSnapshotError.self) {
            _ = try WorkSnapshotMerger.merge(base: base, local: base, remote: remote)
        }
    }

    @Test("delete versus reorder requires review for chapters, episodes, and characters")
    func deleteVersusReorder() throws {
        let base = try WorkTestValues.snapshot()

        let deletedChapter = try WorkTestValues.snapshot { document in
            _ = document.removeChapter(id: WorkTestValues.chapter2)
        }
        let reorderedChapter = try WorkTestValues.snapshot { document in
            document.chapters = [document.chapters[1], document.chapters[0], document.chapters[2]]
        }
        guard case let .conflicted(chapterProposed, chapterConflicts) = try WorkSnapshotMerger.merge(
            base: base,
            local: deletedChapter,
            remote: reorderedChapter
        ) else {
            Issue.record("chapter delete-versus-reorder was silently deleted")
            return
        }
        #expect(chapterConflicts.contains { $0.entityKind == .chapter && $0.reason == .deleteVersusEdit })
        #expect(try chapterProposed.materializedDocument().chapters.first?.id == WorkTestValues.chapter2)

        let deletedEpisode = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes.removeAll { $0.id == WorkTestValues.episode1 }
        }
        let reorderedEpisode = try WorkTestValues.snapshot { document in
            document.chapters[0].episodes.reverse()
        }
        guard case let .conflicted(episodeProposed, episodeConflicts) = try WorkSnapshotMerger.merge(
            base: base,
            local: deletedEpisode,
            remote: reorderedEpisode
        ) else {
            Issue.record("episode delete-versus-reorder was silently deleted")
            return
        }
        #expect(episodeConflicts.contains { $0.entityKind == .episode && $0.reason == .deleteVersusEdit })
        #expect(try episodeProposed.materializedDocument().chapters[0].episodes.first?.id == WorkTestValues.episode2)
        #expect(try episodeProposed.materializedDocument().chapters[0].episodes.last?.id == WorkTestValues.episode1)

        let deletedCharacter = try WorkTestValues.snapshot { document in
            document.characters.removeAll { $0.id == WorkTestValues.character2 }
        }
        let reorderedCharacter = try WorkTestValues.snapshot { document in
            document.characters = [document.characters[1], document.characters[0], document.characters[2]]
        }
        guard case let .conflicted(characterProposed, characterConflicts) = try WorkSnapshotMerger.merge(
            base: base,
            local: deletedCharacter,
            remote: reorderedCharacter
        ) else {
            Issue.record("character delete-versus-reorder was silently deleted")
            return
        }
        #expect(characterConflicts.contains { $0.entityKind == .character && $0.reason == .deleteVersusEdit })
        #expect(try characterProposed.materializedDocument().characters.first?.id == WorkTestValues.character2)
    }

    @Test("conflict budget keeps bounded descriptors plus full proposed snapshot")
    func conflictBudget() throws {
        var baseDocument = WorkTestValues.fullDocument()
        baseDocument.characters = (0 ..< 520).map { index in
            Character(name: "base-\(index)")
        }
        var localDocument = baseDocument
        var remoteDocument = baseDocument
        for index in localDocument.characters.indices {
            localDocument.characters[index].name = "local-\(index)"
            remoteDocument.characters[index].name = "remote-\(index)"
        }
        guard case let .conflicted(proposed, conflicts) = try WorkSnapshotMerger.merge(
            base: WorkSnapshot(document: baseDocument),
            local: WorkSnapshot(document: localDocument),
            remote: WorkSnapshot(document: remoteDocument)
        ) else {
            Issue.record("large conflict set did not require review")
            return
        }
        #expect(conflicts.count == WorkSyncJournalRecord.maximumConflictCount)
        #expect(conflicts.last?.reason == .mergeBudgetExceeded)
        #expect(proposed.characters.count == 520)
        #expect(proposed.characters.allSatisfy { $0.name.hasPrefix("local-") })
    }
}
