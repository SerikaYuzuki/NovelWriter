import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelThumbnail
import Testing

@MainActor
@Suite("macOS thumbnail persistence")
struct ThumbnailPersistenceTests {
    @Test func setReplaceRemoveAndOwnerDeletionCheckpointTogether() async throws {
        let fixture = try await makeFixture()
        let state = fixture.state, application = fixture.application, work = fixture.work
        let character = Character(name: "合成人物"), note = WorldNote(title: "合成世界", content: "合成ノート")
        state.workspaceModel.document.characters = [character]
        state.workspaceModel.document.worldNotes = [note]
        let cover = ThumbnailOwner(.work, state.workspaceModel.document.id)
        let avatar = ThumbnailOwner(.character, character.id.rawValue)
        let world = ThumbnailOwner(.worldNote, note.id.rawValue)
        let orphan = ThumbnailOwner(.character, UUID())
        let session = state.workspaceModel.documentSessionToken, account = state.snapshotSyncV2AccountScopeToken
        let first = try ThumbnailEncoder.encode(SyntheticThumbnailImage.data(), owner: cover)
        let second = try ThumbnailEncoder.encode(SyntheticThumbnailImage.data(), owner: cover, crop: .init(zoom: 2))
        #expect(await state.setThumbnail(first, owner: cover, session: session, account: account))
        #expect(await state.setThumbnail(second, owner: cover, session: session, account: account))
        #expect(state.thumbnailData(cover) == second)
        #expect(state.referenceAttachments.isEmpty)
        #expect(await state.setThumbnail(first, owner: avatar, session: session, account: account))
        #expect(await state.setThumbnail(first, owner: world, session: session, account: account))
        state.snapshotSyncV2Attachments.append(.init(attachmentId: UUID(), fileName: orphan.fileName, bytes: first))
        await state.reloadAttachments()
        #expect(await state.checkpointSnapshotSyncV2(state.workspaceModel.document))
        let before = try await application.openLocal(workID: work)
        #expect(state.deleteCharacter(id: character.id, expectedSession: session))
        #expect(state.deleteWorldNote(id: note.id, expectedSession: session))
        #expect(await state.saveNow())
        let after = try await application.openLocal(workID: work)
        #expect(after.generation == before.generation + 1)
        #expect(after.document?.characters.isEmpty == true)
        #expect(after.document?.worldNotes.isEmpty == true)
        let names = Set(after.attachments.map(\.fileName))
        #expect(names == [cover.fileName, orphan.fileName])
        #expect(state.referenceAttachments.contains { $0.fileName == orphan.fileName })
        #expect(await state.setThumbnail(nil, owner: cover, session: session, account: account))
        #expect(state.thumbnailData(cover) == nil)
        let restored = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(fixture.configuration))
        let reopened = try await restored.openLocal(workID: work)
        #expect(reopened.attachments.count == 1)
        #expect(reopened.attachments.first?.fileName == orphan.fileName)
    }

    @Test func staleAccountAndMissingOwnerCannotWrite() async throws {
        let fixture = try await makeFixture()
        let state = fixture.state
        let owner = ThumbnailOwner(.work, state.workspaceModel.document.id)
        let session = state.workspaceModel.documentSessionToken, account = state.snapshotSyncV2AccountScopeToken
        state.snapshotSyncV2AccountScopeGeneration &+= 1
        #expect(await !state.setThumbnail(Data([1]), owner: owner, session: session, account: account))
        #expect(await !state.setThumbnail(Data([1]), owner: .init(.character, UUID()), session: session,
                                          account: state.snapshotSyncV2AccountScopeToken))
        #expect(state.snapshotSyncV2Attachments.isEmpty)
    }

    @Test func failedCheckpointRestoresPreviousImage() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        var dependencies = AppDependencies(userDefaults: makeIsolatedTestUserDefaults())
        dependencies.snapshotSyncV2CheckpointOverride = { _, _, _, _, _, _, _ in throw CocoaError(.fileWriteUnknown) }
        let state = AppState(dependencies: dependencies, initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        state.installV2Document(.newDocument(title: "合成作品"), workID: WorkID(UUID()), createdAt: Date())
        let owner = ThumbnailOwner(.work, state.workspaceModel.document.id)
        let previous = SyncAttachment(attachmentId: UUID(), fileName: owner.fileName, bytes: Data([1]))
        state.snapshotSyncV2Attachments = [previous]
        await state.reloadAttachments()
        #expect(await !state.setThumbnail(Data([2]), owner: owner, session: state.workspaceModel.documentSessionToken,
                                          account: state.snapshotSyncV2AccountScopeToken))
        #expect(state.snapshotSyncV2Attachments == [previous])
        #expect(state.workspaceModel.attachments.first?.fileName == owner.fileName)
    }

    private func makeFixture() async throws -> Fixture {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        let document = NovelDocument.newDocument(title: "合成作品"), work = WorkID(UUID())
        state.installV2Document(document, workID: work, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(await state.checkpointSnapshotSyncV2(document))
        return Fixture(state: state, application: application, work: work, configuration: configuration)
    }

    private struct Fixture {
        let state: AppState
        let application: SyncV2Application
        let work: WorkID
        let configuration: TestRuntimeConfiguration
    }
}

@MainActor
private final class ThumbnailCheckpointPause {
    var continuation: CheckedContinuation<Void, Never>?
    var didPause = false
    func pauseOnce() async {
        guard !didPause else { return }
        didPause = true
        await withCheckedContinuation { continuation = $0 }
    }
}

extension ThumbnailPersistenceTests {
    @Test func failedImageSaveDoesNotResurrectAnOwnerDeletedWhileSaving() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let pause = ThumbnailCheckpointPause()
        var dependencies = AppDependencies(userDefaults: makeIsolatedTestUserDefaults())
        dependencies.snapshotSyncV2CheckpointOverride = { _, _, _, _, _, _, _ in
            await pause.pauseOnce()
            throw CocoaError(.fileWriteUnknown)
        }
        let state = AppState(dependencies: dependencies, initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        let character = Character(name: "合成人物")
        let document = NovelDocument(title: "合成作品", chapters: [], characters: [character])
        state.installV2Document(document, workID: WorkID(UUID()), createdAt: Date())
        let owner = ThumbnailOwner(.character, character.id.rawValue)
        state.snapshotSyncV2Attachments = [.init(attachmentId: UUID(), fileName: owner.fileName, bytes: Data([1]))]
        await state.reloadAttachments()
        let task = Task {
            await state.setThumbnail(Data([2]), owner: owner, session: state.workspaceModel.documentSessionToken,
                                     account: state.snapshotSyncV2AccountScopeToken)
        }
        for _ in 0 ..< 100 {
            if pause.continuation != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let continuation = try #require(pause.continuation)
        #expect(state.deleteCharacter(id: character.id))
        continuation.resume()
        #expect(await !task.value)
        #expect(state.workspaceModel.document.characters.isEmpty)
        #expect(state.thumbnailData(owner) == nil)
    }
}
