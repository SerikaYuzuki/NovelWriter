import Foundation
import NovelCore

extension IOSDocumentStore {
    var currentPrivateDocumentID: IOSPrivateDocumentID? {
        guard startupState == .ready,
              let privateWorkingCopyLocation,
              let attestation = try? privateWorkingCopyLocation.attestPackage(at: documentURL) else { return nil }
        return attestation.id
    }

    var currentDocumentSessionToken: IOSDocumentSessionToken? {
        guard let workingCopyID = currentPrivateDocumentID else { return nil }
        return IOSDocumentSessionToken(
            workingCopyID: workingCopyID,
            generation: documentSessionGeneration
        )
    }

    var currentEpisodeEditingToken: IOSEpisodeEditingToken? {
        guard let documentSession = currentDocumentSessionToken,
              let selectedChapterID,
              let selectedEpisodeID else { return nil }
        return IOSEpisodeEditingToken(
            documentSession: documentSession,
            chapterID: selectedChapterID,
            episodeID: selectedEpisodeID,
            editorContentGeneration: editorContentGeneration
        )
    }

    // MARK: - Characters

    @discardableResult
    func addCharacter(
        name: String = "名無し",
        expectedSession: IOSDocumentSessionToken
    ) -> CharacterID? {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession) else { return nil }
        let id = document.addCharacter(name: name)
        markDocumentChanged()
        return id
    }

    @discardableResult
    func updateCharacter(
        _ character: NovelCore.Character,
        expectedSession: IOSDocumentSessionToken
    ) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              let current = document.characters.first(where: { $0.id == character.id }),
              current != character else { return false }
        document.updateCharacter(
            id: character.id,
            name: character.name,
            kana: character.kana,
            memo: character.memo,
            colorHex: character.colorHex,
            role: character.role,
            age: character.age,
            gender: character.gender,
            firstPerson: character.firstPerson,
            secondPerson: character.secondPerson,
            speechStyle: character.speechStyle,
            appearance: character.appearance,
            personality: character.personality,
            background: character.background
        )
        markDocumentChanged()
        return true
    }

    @discardableResult
    func deleteCharacter(id: CharacterID, expectedSession: IOSDocumentSessionToken) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              document.removeCharacter(id: id) != nil else { return false }
        markDocumentChanged()
        return true
    }

    @discardableResult
    func moveCharacters(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: IOSDocumentSessionToken
    ) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              Self.isValidMove(
                  fromOffsets: fromOffsets,
                  toOffset: toOffset,
                  count: document.characters.count
              ) else { return false }
        document.moveCharacters(fromOffsets: fromOffsets, toOffset: toOffset)
        markDocumentChanged()
        return true
    }

    // MARK: - Plot cards

    @discardableResult
    func addPlotCard(
        title: String = "新しいカード",
        chapterID: ChapterID? = nil,
        expectedSession: IOSDocumentSessionToken
    ) -> PlotCardID? {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              isCurrentChapterID(chapterID) else { return nil }
        let id = document.addPlotCard(title: title, chapterID: chapterID)
        markDocumentChanged()
        return id
    }

    @discardableResult
    func updatePlotCard(
        _ card: PlotCard,
        expectedSession: IOSDocumentSessionToken
    ) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              isCurrentChapterID(card.chapterID),
              let current = document.plotCards.first(where: { $0.id == card.id }),
              current != card else { return false }
        document.updatePlotCard(
            id: card.id,
            title: card.title,
            memo: card.memo,
            chapterID: card.chapterID
        )
        markDocumentChanged()
        return true
    }

    @discardableResult
    func deletePlotCard(id: PlotCardID, expectedSession: IOSDocumentSessionToken) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              document.removePlotCard(id: id) != nil else { return false }
        markDocumentChanged()
        return true
    }

    @discardableResult
    func movePlotCards(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: IOSDocumentSessionToken
    ) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              Self.isValidMove(
                  fromOffsets: fromOffsets,
                  toOffset: toOffset,
                  count: document.plotCards.count
              ) else { return false }
        document.movePlotCards(fromOffsets: fromOffsets, toOffset: toOffset)
        markDocumentChanged()
        return true
    }

    // MARK: - Flags

    @discardableResult
    func addFlag(
        title: String = "新しい伏線",
        expectedSession: IOSDocumentSessionToken
    ) -> FlagID? {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession) else { return nil }
        let id = document.addFlag(title: title)
        markDocumentChanged()
        return id
    }

    @discardableResult
    func updateFlag(
        _ flag: Flag,
        expectedSession: IOSDocumentSessionToken
    ) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              isCurrentChapterID(flag.plantedChapterID),
              isCurrentChapterID(flag.resolvedChapterID),
              let current = document.flags.first(where: { $0.id == flag.id }),
              current != flag else { return false }
        document.updateFlag(flag)
        markDocumentChanged()
        return true
    }

    @discardableResult
    func deleteFlag(id: FlagID, expectedSession: IOSDocumentSessionToken) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              document.removeFlag(id: id) != nil else { return false }
        markDocumentChanged()
        return true
    }

    @discardableResult
    func moveFlags(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: IOSDocumentSessionToken
    ) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              Self.isValidMove(
                  fromOffsets: fromOffsets,
                  toOffset: toOffset,
                  count: document.flags.count
              ) else { return false }
        document.moveFlags(fromOffsets: fromOffsets, toOffset: toOffset)
        markDocumentChanged()
        return true
    }

    // MARK: - World notes

    @discardableResult
    func addWorldNote(
        title: String = "新しいノート",
        expectedSession: IOSDocumentSessionToken
    ) -> WorldNoteID? {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession) else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = WorldNote(title: trimmedTitle.isEmpty ? "新しいノート" : trimmedTitle)
        document.worldNotes.append(note)
        markDocumentChanged()
        return note.id
    }

    @discardableResult
    func updateWorldNote(
        _ note: WorldNote,
        expectedSession: IOSDocumentSessionToken
    ) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              let index = document.worldNotes.firstIndex(where: { $0.id == note.id }),
              document.worldNotes[index] != note else { return false }
        document.worldNotes[index] = note
        markDocumentChanged()
        return true
    }

    @discardableResult
    func deleteWorldNote(id: WorldNoteID, expectedSession: IOSDocumentSessionToken) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              let index = document.worldNotes.firstIndex(where: { $0.id == id }) else { return false }
        document.worldNotes.remove(at: index)
        markDocumentChanged()
        return true
    }

    @discardableResult
    func moveWorldNotes(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: IOSDocumentSessionToken
    ) -> Bool {
        guard permitsProjectFeatureMutation,
              validateCurrentDocumentSession(expectedSession),
              Self.isValidMove(
                  fromOffsets: fromOffsets,
                  toOffset: toOffset,
                  count: document.worldNotes.count
              ) else { return false }
        Self.moveWorldNotes(&document.worldNotes, fromOffsets: fromOffsets, toOffset: toOffset)
        markDocumentChanged()
        return true
    }

    private var permitsProjectFeatureMutation: Bool {
        startupState == .ready && !isDocumentTransitionInProgress
    }

    private func isCurrentChapterID(_ id: ChapterID?) -> Bool {
        guard let id else { return true }
        return document.chapters.contains(where: { $0.id == id })
    }

    func matchesCurrentDocumentSession(_ expectedSession: IOSDocumentSessionToken) -> Bool {
        currentDocumentSessionToken == expectedSession
    }

    func validateCurrentDocumentSession(_ expectedSession: IOSDocumentSessionToken) -> Bool {
        guard matchesCurrentDocumentSession(expectedSession) else {
            operationErrorMessage = "作品が切り替わったため、この操作を中止しました。"
            return false
        }
        return true
    }

    private static func isValidMove(fromOffsets: IndexSet, toOffset: Int, count: Int) -> Bool {
        !fromOffsets.isEmpty &&
            fromOffsets.allSatisfy { (0 ..< count).contains($0) } &&
            (0 ... count).contains(toOffset)
    }

    private static func moveWorldNotes(
        _ items: inout [WorldNote],
        fromOffsets: IndexSet,
        toOffset: Int
    ) {
        let movingItems = fromOffsets.map { items[$0] }
        for index in fromOffsets.sorted(by: >) {
            items.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.count(where: { $0 < toOffset })
        items.insert(contentsOf: movingItems, at: toOffset - removedBeforeDestination)
    }
}
