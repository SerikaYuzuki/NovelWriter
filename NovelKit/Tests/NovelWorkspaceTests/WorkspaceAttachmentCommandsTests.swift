import Foundation
import NovelCore
import NovelSyncV2
import NovelThumbnail
import NovelWorkspace
import Testing

@MainActor
@Suite("Shared attachments and thumbnails")
struct WorkspaceAttachmentCommandsTests {
    @Test func namesOrderAndRenamePreserveIdentity() async throws {
        let host = FakeWorkspaceHost()
        var candidates: [WorkspaceAttachmentSet] = []
        let commands = WorkspaceAttachmentCommands(host: host, boundary: { await $0() }, checkpoint: { _, candidate in
            #expect(host.workspaceAttachments != candidate)
            candidates.append(candidate)
            return true
        })
        let context = host.operationContext
        let first = try #require(await commands.add(Data([1]), named: "資料.pdf", style: .parentheses, context: context))
        let second = try #require(await commands.add(Data([2]), named: "資料.pdf", style: .parentheses, context: context))
        #expect(second.fileName == "資料 (2).pdf")
        let names = host.workspaceAttachments.records.map(\.fileName)
        #expect(names == [first.fileName, second.fileName])
        #expect(host.workspaceAttachments.uniqueName("資料.pdf", style: .hyphen) == "資料-2.pdf")
        #expect(await commands.rename(first.fileName, to: second.fileName, style: .parentheses, context: context))
        let renamed = try #require(host.workspaceAttachments.records.first)
        #expect(renamed.attachmentId == first.attachmentId)
        #expect(renamed.bytes == first.bytes)
        #expect(renamed.fileName == "資料 (2) (2).pdf")
        #expect(await commands.delete(named: second.fileName, context: context))
        #expect(host.workspaceAttachments.records == [renamed])
        #expect(candidates.count == 4)
        let owner = ThumbnailOwner(.work, host.document.id)
        let imported = try #require(await commands.add(Data([3]), named: owner.fileName, style: .hyphen, context: context))
        #expect(imported.fileName == "資料-" + owner.fileName)
        #expect(await !commands.rename(imported.fileName, to: owner.fileName, style: .hyphen, context: context))
        #expect(WorkspaceAttachmentSet([first, first]) == nil)
        #expect(WorkspaceAttachmentSet([first, .init(attachmentId: UUID(), fileName: first.fileName, bytes: Data())]) == nil)
    }

    @Test func thumbnailReplacementAndOwnerRemovalPreserveOtherResources() async throws {
        let host = FakeWorkspaceHost()
        let character = Character(name: "人物"), note = WorldNote(title: "世界", content: "")
        host.document.characters = [character]
        host.document.worldNotes = [note]
        let cover = ThumbnailOwner(.work, host.document.id)
        let avatar = ThumbnailOwner(.character, character.id.rawValue)
        let world = ThumbnailOwner(.worldNote, note.id.rawValue)
        let orphan = ThumbnailOwner(.character, UUID())
        host.workspaceAttachments = try #require(WorkspaceAttachmentSet([
            .init(attachmentId: UUID(), fileName: orphan.fileName, bytes: Data([9])),
            .init(attachmentId: UUID(), fileName: "資料.txt", bytes: Data([8]))
        ]))
        let commands = WorkspaceAttachmentCommands(host: host, boundary: { await $0() }, checkpoint: { _, _ in true })
        let context = host.operationContext
        for owner in [cover, avatar, world] {
            #expect(await commands.setThumbnail(Data([1]), owner: owner, context: context))
        }
        let previousID = host.workspaceAttachments[cover.fileName]?.attachmentId
        #expect(await commands.setThumbnail(Data([2]), owner: cover, context: context))
        #expect(host.workspaceAttachments.records.last?.fileName == cover.fileName)
        #expect(host.workspaceAttachments[cover.fileName]?.attachmentId != previousID)
        let projects = ProjectFeatureCommands(host: host, policy: .debounced)
        #expect(projects.deleteCharacter(id: character.id, expectedSession: host.session))
        #expect(projects.deleteWorldNote(id: note.id, expectedSession: host.session))
        let names = host.workspaceAttachments.records.map(\.fileName)
        #expect(names == [orphan.fileName, "資料.txt", cover.fileName])
        #expect(host.markedDocuments.last?.worldNotes.isEmpty == true)
        #expect(await commands.setThumbnail(nil, owner: cover, context: context))
        #expect(host.workspaceAttachments[cover.fileName] == nil)
    }

    @Test func failedCheckpointAndStaleCompletionDoNotInstallCandidate() async {
        let host = FakeWorkspaceHost()
        let owner = ThumbnailOwner(.work, host.document.id)
        host.workspaceAttachments = host.workspaceAttachments.settingThumbnail(Data([1]), owner: owner)
        let previous = host.workspaceAttachments
        let failed = WorkspaceAttachmentCommands(host: host, boundary: { await $0() }, checkpoint: { _, _ in false })
        let context = host.operationContext
        #expect(await !failed.setThumbnail(Data([2]), owner: owner, context: context))
        #expect(await failed.add(Data([3]), named: "資料", style: .parentheses, context: context) == nil)
        #expect(await !failed.delete(named: owner.fileName, context: context))
        #expect(host.workspaceAttachments == previous)
        let stale = WorkspaceAttachmentCommands(host: host, boundary: { await $0() }, checkpoint: { _, _ in
            host.session.generation += 1
            return true
        })
        #expect(await !stale.setThumbnail(Data([2]), owner: owner, context: context))
        #expect(host.workspaceAttachments == previous)
    }

    @Test func concurrentOwnerDeletionSurvivesFailedAndSuccessfulCheckpoint() async {
        for saves in [false, true] {
            let host = FakeWorkspaceHost()
            let character = Character(name: "人物")
            host.document.characters = [character]
            let owner = ThumbnailOwner(.character, character.id.rawValue)
            host.workspaceAttachments = host.workspaceAttachments.settingThumbnail(Data([1]), owner: owner)
            let commands = WorkspaceAttachmentCommands(host: host, boundary: { await $0() }, checkpoint: { _, _ in
                #expect(ProjectFeatureCommands(host: host, policy: .debounced).deleteCharacter(
                    id: character.id, expectedSession: host.session
                ))
                return saves
            })
            #expect(await !commands.setThumbnail(Data([2]), owner: owner, context: host.operationContext))
            #expect(host.document.characters.isEmpty)
            #expect(host.workspaceAttachments.records.isEmpty)
        }
    }
}
