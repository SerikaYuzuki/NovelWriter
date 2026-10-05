import Foundation
import NovelCore

/// Synchronous project edits. Selection, editor transitions and persistence stay in the host.
@MainActor
public struct ProjectFeatureCommands {
    private let host: any WorkspaceHost
    private let policy: WorkspaceSavePolicy

    public init(host: any WorkspaceHost, policy: WorkspaceSavePolicy) {
        self.host = host
        self.policy = policy
    }

    // MARK: - Characters

    @discardableResult
    public func addCharacter(
        name: String = "名無し",
        expectedSession: WorkspaceSessionToken
    ) -> CharacterID? {
        guard permitsMutation(expectedSession) else { return nil }
        let id = host.document.addCharacter(name: name)
        host.markChanged(policy: policy)
        return id
    }

    @discardableResult
    public func updateCharacter(
        _ character: NovelCore.Character,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsMutation(expectedSession),
              let current = host.document.characters.first(where: { $0.id == character.id }),
              current != character else { return false }
        host.document.updateCharacter(
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
        host.markChanged(policy: policy)
        return true
    }

    @discardableResult
    public func deleteCharacter(id: CharacterID, expectedSession: WorkspaceSessionToken) -> Bool {
        guard permitsMutation(expectedSession) else { return false }
        var replacement = host.document
        guard replacement.removeCharacter(id: id) != nil else { return false }
        host.applyOwnerRemoval(replacement)
        host.markChanged(policy: policy)
        return true
    }

    @discardableResult
    public func moveCharacters(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsMutation(expectedSession),
              Self.isValidMove(
                  fromOffsets: fromOffsets,
                  toOffset: toOffset,
                  count: host.document.characters.count
              ) else { return false }
        host.document.moveCharacters(fromOffsets: fromOffsets, toOffset: toOffset)
        host.markChanged(policy: policy)
        return true
    }

    // MARK: - Plot cards

    @discardableResult
    public func addPlotCard(
        title: String = "新しいカード",
        chapterID: ChapterID? = nil,
        expectedSession: WorkspaceSessionToken
    ) -> PlotCardID? {
        guard permitsMutation(expectedSession),
              isCurrentChapterID(chapterID) else { return nil }
        let id = host.document.addPlotCard(title: title, chapterID: chapterID)
        host.markChanged(policy: policy)
        return id
    }

    @discardableResult
    public func updatePlotCard(
        _ card: PlotCard,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsMutation(expectedSession),
              isCurrentChapterID(card.chapterID),
              let current = host.document.plotCards.first(where: { $0.id == card.id }),
              current != card else { return false }
        host.document.updatePlotCard(
            id: card.id,
            title: card.title,
            memo: card.memo,
            chapterID: card.chapterID
        )
        host.markChanged(policy: policy)
        return true
    }

    @discardableResult
    public func deletePlotCard(id: PlotCardID, expectedSession: WorkspaceSessionToken) -> Bool {
        guard permitsMutation(expectedSession),
              host.document.removePlotCard(id: id) != nil else { return false }
        host.markChanged(policy: policy)
        return true
    }

    @discardableResult
    public func movePlotCards(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsMutation(expectedSession),
              Self.isValidMove(
                  fromOffsets: fromOffsets,
                  toOffset: toOffset,
                  count: host.document.plotCards.count
              ) else { return false }
        host.document.movePlotCards(fromOffsets: fromOffsets, toOffset: toOffset)
        host.markChanged(policy: policy)
        return true
    }

    // MARK: - Flags

    @discardableResult
    public func addFlag(
        title: String = "新しい伏線",
        plantedChapterID: ChapterID? = nil,
        expectedSession: WorkspaceSessionToken
    ) -> FlagID? {
        guard permitsMutation(expectedSession),
              isCurrentChapterID(plantedChapterID) else { return nil }
        let id = host.document.addFlag(title: title, plantedChapterID: plantedChapterID)
        host.markChanged(policy: policy)
        return id
    }

    @discardableResult
    public func updateFlag(
        _ flag: Flag,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsMutation(expectedSession),
              isCurrentChapterID(flag.plantedChapterID),
              isCurrentChapterID(flag.resolvedChapterID),
              let current = host.document.flags.first(where: { $0.id == flag.id }),
              current != flag else { return false }
        host.document.updateFlag(flag)
        host.markChanged(policy: policy)
        return true
    }

    @discardableResult
    public func deleteFlag(id: FlagID, expectedSession: WorkspaceSessionToken) -> Bool {
        guard permitsMutation(expectedSession),
              host.document.removeFlag(id: id) != nil else { return false }
        host.markChanged(policy: policy)
        return true
    }

    @discardableResult
    public func moveFlags(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsMutation(expectedSession),
              Self.isValidMove(
                  fromOffsets: fromOffsets,
                  toOffset: toOffset,
                  count: host.document.flags.count
              ) else { return false }
        host.document.moveFlags(fromOffsets: fromOffsets, toOffset: toOffset)
        host.markChanged(policy: policy)
        return true
    }
}

public extension ProjectFeatureCommands {
    // MARK: - World notes

    @discardableResult
    func addWorldNote(_ note: WorldNote, expectedSession: WorkspaceSessionToken) -> WorldNoteID? {
        guard permitsMutation(expectedSession) else { return nil }
        host.document.worldNotes.append(note)
        host.markChanged(policy: policy)
        return note.id
    }

    @discardableResult
    func updateWorldNote(
        _ note: WorldNote,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsMutation(expectedSession),
              let index = host.document.worldNotes.firstIndex(where: { $0.id == note.id }),
              host.document.worldNotes[index] != note else { return false }
        host.document.worldNotes[index] = note
        host.markChanged(policy: policy)
        return true
    }

    @discardableResult
    func deleteWorldNote(id: WorldNoteID, expectedSession: WorkspaceSessionToken) -> Bool {
        guard permitsMutation(expectedSession),
              let index = host.document.worldNotes.firstIndex(where: { $0.id == id }) else { return false }
        var replacement = host.document
        replacement.worldNotes.remove(at: index)
        host.applyOwnerRemoval(replacement)
        host.markChanged(policy: policy)
        return true
    }

    @discardableResult
    func moveWorldNotes(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsMutation(expectedSession),
              Self.isValidMove(
                  fromOffsets: fromOffsets,
                  toOffset: toOffset,
                  count: host.document.worldNotes.count
              ) else { return false }
        Self.moveWorldNotes(&host.document.worldNotes, fromOffsets: fromOffsets, toOffset: toOffset)
        host.markChanged(policy: policy)
        return true
    }

    @discardableResult
    func movePlotCard(
        id: PlotCardID,
        toChapter chapterID: ChapterID?,
        before targetID: PlotCardID? = nil,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsMutation(expectedSession),
              isCurrentChapterID(chapterID),
              host.document.plotCards.contains(where: { $0.id == id }) else { return false }
        host.document.movePlotCard(id: id, toChapter: chapterID, before: targetID)
        host.markChanged(policy: policy)
        return true
    }

    private func permitsMutation(_ expectedSession: WorkspaceSessionToken) -> Bool {
        host.permitsLocalMutation && host.operationContext.session == expectedSession
    }

    private func isCurrentChapterID(_ id: ChapterID?) -> Bool {
        guard let id else { return true }
        return host.document.chapters.contains(where: { $0.id == id })
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
