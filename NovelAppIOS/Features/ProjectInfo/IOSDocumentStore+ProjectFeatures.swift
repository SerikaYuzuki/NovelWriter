import Foundation
import NovelCore
import NovelWorkspace

extension IOSDocumentStore {
    @discardableResult
    func addCharacter(
        name: String = "名無し",
        expectedSession: WorkspaceSessionToken
    ) -> CharacterID? {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return nil }
        return ProjectFeatureCommands(host: self, policy: .debounced).addCharacter(
            name: name,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func updateCharacter(
        _ character: NovelCore.Character,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).updateCharacter(
            character,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func deleteCharacter(id: CharacterID, expectedSession: WorkspaceSessionToken) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).deleteCharacter(
            id: id,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func moveCharacters(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).moveCharacters(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func addPlotCard(
        title: String = "新しいカード",
        chapterID: ChapterID? = nil,
        expectedSession: WorkspaceSessionToken
    ) -> PlotCardID? {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return nil }
        return ProjectFeatureCommands(host: self, policy: .debounced).addPlotCard(
            title: title,
            chapterID: chapterID,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func updatePlotCard(
        _ card: PlotCard,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).updatePlotCard(
            card,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func deletePlotCard(id: PlotCardID, expectedSession: WorkspaceSessionToken) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).deletePlotCard(
            id: id,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func movePlotCards(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).movePlotCards(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func addFlag(
        title: String = "新しい伏線",
        expectedSession: WorkspaceSessionToken
    ) -> FlagID? {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return nil }
        return ProjectFeatureCommands(host: self, policy: .debounced).addFlag(
            title: title,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func updateFlag(
        _ flag: Flag,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).updateFlag(flag, expectedSession: expectedSession)
    }

    @discardableResult
    func deleteFlag(id: FlagID, expectedSession: WorkspaceSessionToken) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).deleteFlag(
            id: id,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func moveFlags(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).moveFlags(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func addWorldNote(
        title: String = "新しいノート",
        expectedSession: WorkspaceSessionToken
    ) -> WorldNoteID? {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = WorldNote(title: trimmedTitle.isEmpty ? "新しいノート" : trimmedTitle)
        return ProjectFeatureCommands(host: self, policy: .debounced).addWorldNote(
            note,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func updateWorldNote(
        _ note: WorldNote,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).updateWorldNote(
            note,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func deleteWorldNote(id: WorldNoteID, expectedSession: WorkspaceSessionToken) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).deleteWorldNote(
            id: id,
            expectedSession: expectedSession
        )
    }

    @discardableResult
    func moveWorldNotes(
        fromOffsets: IndexSet,
        toOffset: Int,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        guard permitsLocalMutation,
              validateCurrentDocumentSession(expectedSession) else { return false }
        return ProjectFeatureCommands(host: self, policy: .debounced).moveWorldNotes(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            expectedSession: expectedSession
        )
    }

    func matchesCurrentDocumentSession(_ expectedSession: WorkspaceSessionToken) -> Bool {
        currentDocumentSessionToken == expectedSession
    }

    func validateCurrentDocumentSession(_ expectedSession: WorkspaceSessionToken) -> Bool {
        guard matchesCurrentDocumentSession(expectedSession) else {
            operationErrorMessage = "作品が切り替わったため、この操作を中止しました。"
            return false
        }
        return true
    }
}
