import Foundation
@testable import FUMINIWA
import ImageIO
import NovelCore
import NovelSyncV2
import NovelSyncV2Runtime
import NovelThumbnail
import NovelWritingSupport
import Testing
import UniformTypeIdentifiers

@MainActor
struct MCPThumbnailTests {
    @Test(arguments: ThumbnailOwner.Kind.allCases)
    func imageAbsentSetReadAndUndo(kind: ThumbnailOwner.Kind) async throws {
        let fixture = try await MCPThumbnailHarness.make(), owner = fixture.owner(kind)
        let empty = try await fixture.call("read_thumbnail", fixture.arguments(owner))
        #expect(try fixture.output(empty)["exists"] as? Bool == false)
        let image = try MCPThumbnailHarness.source(), id = UUID()
        let args = try fixture.arguments(owner, requestID: id, image: image)
        #expect(try await fixture.call("set_thumbnail", args)["isError"] as? Bool == false)
        let saved = try #require(fixture.state.thumbnailData(owner))
        #expect(try saved == (ThumbnailEncoder.encode(image, owner: owner)))
        let response = try await fixture.call("read_thumbnail", fixture.arguments(owner))
        let content = try #require((response["content"] as? [[String: Any]])?.first)
        #expect(content["type"] as? String == "image")
        #expect(content["mimeType"] as? String == "image/jpeg")
        #expect(content["data"] as? String == saved.base64EncodedString())
        #expect(try await fixture.undo(id)["isError"] as? Bool == false)
        #expect(fixture.state.thumbnailData(owner) == nil)
        #expect(try await fixture.application.openLocal(workID: fixture.work).attachments.isEmpty)
    }

    @Test(arguments: [WritingMCPVersion.november2025, .july2026])
    func replacementCropReplayAndRemovalUndo(version: WritingMCPVersion) async throws {
        let fixture = try await MCPThumbnailHarness.make(), owner = fixture.owner(.character)
        let original = try ThumbnailEncoder.encode(MCPThumbnailHarness.source(), owner: owner)
        #expect(await fixture.state.setThumbnail(original, owner: owner, session: fixture.state.workspaceModel.documentSessionToken,
                                                 account: fixture.state.snapshotSyncV2AccountScopeToken))
        let before = fixture.state.snapshotSyncV2Attachments, id = UUID()
        let source = try MCPThumbnailHarness.source(.jpeg)
        var args = try fixture.arguments(owner, requestID: id, image: source)
        args["crop"] = ["centerX": 0.75, "centerY": 0.5, "zoom": 2.0]
        let result = try await fixture.call("set_thumbnail", args, version: version)
        #expect(result["isError"] as? Bool == false)
        let replacement = fixture.state.snapshotSyncV2Attachments
        #expect(try fixture.state.thumbnailData(owner) == (ThumbnailEncoder.encode(
            source,
            owner: owner,
            crop: .init(centerX: 0.75, zoom: 2)
        )))
        let local = try await fixture.application.openLocal(workID: fixture.work)
        let replay = try await fixture.call("set_thumbnail", args, version: version)
        #expect(try fixture.output(replay)["replayed"] as? Bool == true)
        #expect(fixture.state.snapshotSyncV2Attachments == replacement)
        #expect(try await fixture.application.openLocal(workID: fixture.work).generation == local.generation)
        var reused = args; reused["crop"] = ["zoom": 3.0]
        #expect(try await fixture.call("set_thumbnail", reused)["isError"] as? Bool == true)
        #expect(try await fixture.undo(id)["isError"] as? Bool == false)
        #expect(fixture.state.snapshotSyncV2Attachments == before)
        #expect(try await fixture.call("set_thumbnail", args)["isError"] as? Bool == false)
        #expect(fixture.state.snapshotSyncV2Attachments == before)
        let removal = UUID(), removing = try fixture.arguments(owner, requestID: removal)
        #expect(try await fixture.call("remove_thumbnail", removing)["isError"] as? Bool == false)
        #expect(fixture.state.thumbnailData(owner) == nil)
        #expect(try await fixture.call("remove_thumbnail", removing)["isError"] as? Bool == false)
        #expect(try await fixture.undo(removal)["isError"] as? Bool == false)
        #expect(fixture.state.snapshotSyncV2Attachments == before)
    }

    @Test func sourceValidationAndScopeCannotChangeImage() async throws {
        let fixture = try await MCPThumbnailHarness.make(), owner = fixture.owner()
        for source in try [Data([1, 2, 3]), MCPThumbnailHarness.source(.gif, frames: 2),
                           MCPThumbnailHarness.source(width: 8193, height: 1),
                           Data(repeating: 0, count: WritingMCPThumbnailImage.maximumSourceBytes + 1)] {
            #expect(try await fixture.call("set_thumbnail", fixture.arguments(
                owner,
                image: source
            ))["isError"] as? Bool == true)
        }
        var args = try fixture.arguments(owner, image: MCPThumbnailHarness.source())
        args["image"] = "%%%"
        #expect(try await fixture.call("set_thumbnail", args)["isError"] as? Bool == true)
        args["image"] = try MCPThumbnailHarness.source().base64EncodedString()
        args["scope"] = ["paths": [["characters"]], "appendOnly": false]
        #expect(try await fixture.call("set_thumbnail", args)["isError"] as? Bool == true)
        args["scope"] = ["paths": [WritingMCPThumbnailRequest.path(fixture.owner(.character))], "appendOnly": false]
        #expect(try await fixture.call("set_thumbnail", args)["isError"] as? Bool == true)
        args["scope"] = ["paths": [WritingMCPThumbnailRequest.path(owner)], "appendOnly": true]
        #expect(try await fixture.call("set_thumbnail", args)["isError"] as? Bool == true)
        args["scope"] = ["paths": [WritingMCPThumbnailRequest.path(owner)], "appendOnly": false]
        for crop: [String: Any] in [["centerX": -0.1], ["centerY": 1.1], ["zoom": 9], ["centerX": true]] {
            args["crop"] = crop
            #expect(try await fixture.call("set_thumbnail", args)["isError"] as? Bool == true)
        }
        #expect(fixture.state.snapshotSyncV2Attachments.isEmpty)
        let context = try await fixture.application.writingContext(workID: fixture.work)
        #expect(try await fixture.application.writingRecords(context: context).isEmpty)
    }

    @Test func targetWorkSessionAndAccountAreCheckedForReadAndWrite() async throws {
        let fixture = try await MCPThumbnailHarness.make()
        for name in ["read_thumbnail", "set_thumbnail", "remove_thumbnail"] {
            let good = try fixture.arguments(fixture.owner(), image: MCPThumbnailHarness.source())
            for (field, value) in [("workId", UUID().uuidString as Any), ("sessionId", "old-session" as Any),
                                   ("target", ["kind": "work", "id": fixture.work.description] as Any),
                                   ("target", ["kind": "character", "id": UUID().uuidString] as Any)] {
                var bad = good; bad[field] = value
                #expect(try await fixture.call(name, bad)["isError"] as? Bool == true)
            }
        }
        let old = try #require(fixture.state.writingAssistantHost)
        let args = try fixture.arguments(fixture.owner(), image: MCPThumbnailHarness.source())
        fixture.state.snapshotSyncV2AccountScopeGeneration &+= 1
        #expect(try await fixture.call("read_thumbnail", args, host: old)["isError"] as? Bool == true)
        #expect(try await fixture.call("set_thumbnail", args, host: old)["isError"] as? Bool == true)
        #expect(fixture.state.snapshotSyncV2Attachments.isEmpty)
    }

    @Test func undoSurvivesRestartAndRecordsNeverContainImages() async throws {
        let fixture = try await MCPThumbnailHarness.make(), owner = fixture.owner()
        let original = try ThumbnailEncoder.encode(MCPThumbnailHarness.source(), owner: owner)
        #expect(await fixture.state.setThumbnail(original, owner: owner, session: fixture.state.workspaceModel.documentSessionToken,
                                                 account: fixture.state.snapshotSyncV2AccountScopeToken))
        let before = fixture.state.snapshotSyncV2Attachments
        let source = try MCPThumbnailHarness.source(.jpeg), id = UUID()
        var args = try fixture.arguments(owner, requestID: id, image: source); args["crop"] = ["zoom": 2]
        #expect(try await fixture.call("set_thumbnail", args)["isError"] as? Bool == false)
        let context = try await fixture.application.writingContext(workID: fixture.work)
        let records = try await fixture.application.writingRecords(context: context)
        #expect(records.contains { $0.record.kind == "edit" })
        for envelope in records {
            #expect(envelope.record.payload.utf8.count < 2000)
            #expect(!envelope.record.payload.contains(source.base64EncodedString()))
            #expect(!envelope.record.payload.contains(original.base64EncodedString()))
            #expect(!envelope.record.payload.contains("bytes"))
        }
        let journal = try #require(await fixture.application.writingEdit(id: id, context: context))
        let stored = try JSONDecoder().decode(WritingStoredEdit.self, from: Data(journal.payload.utf8))
        #expect(stored.prepared.changes.first?.before != nil)
        #expect(journal.payload.utf8.count <= 600_000)
        let restarted = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(fixture.configuration))
        let local = try await restarted.openLocal(workID: fixture.work)
        let document = try #require(local.document)
        let state = AppState(
            dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()),
            initialStartupState: .ready
        )
        state.snapshotSyncV2Application = restarted
        state.installV2Document(document, workID: fixture.work, createdAt: local.documentCreatedAt)
        state.snapshotSyncV2Attachments = local.attachments
        await state.reloadAttachments()
        let host = try #require(state.writingAssistantHost)
        args["sessionId"] = host.contextID
        let undoResult = try await fixture.call("undo_edit", args, host: host)
        let message = (undoResult["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(undoResult["isError"] as? Bool == false, "\(message ?? "Undo response missing")")
        #expect(state.snapshotSyncV2Attachments == before)
        #expect(try await restarted.openLocal(workID: fixture.work).attachments == before)
    }

    @Test func undoDoesNotOverwriteLaterManualImageOrRemovedOwner() async throws {
        let fixture = try await MCPThumbnailHarness.make(), owner = fixture.owner(.character), id = UUID()
        #expect(try await fixture.call(
            "set_thumbnail",
            fixture.arguments(owner, requestID: id, image: MCPThumbnailHarness.source())
        )["isError"] as? Bool == false)
        let manual = try ThumbnailEncoder.encode(MCPThumbnailHarness.source(), owner: owner, crop: .init(zoom: 3))
        #expect(await fixture.state.setThumbnail(manual, owner: owner, session: fixture.state.workspaceModel.documentSessionToken,
                                                 account: fixture.state.snapshotSyncV2AccountScopeToken))
        #expect(try await fixture.undo(id)["isError"] as? Bool == true)
        #expect(fixture.state.thumbnailData(owner) == manual)
        #expect(fixture.state.deleteCharacter(id: fixture.state.workspaceModel.document.characters[0].id))
        #expect(try await fixture.undo(id)["isError"] as? Bool == true)
        #expect(fixture.state.thumbnailData(owner) == nil)
    }
}
