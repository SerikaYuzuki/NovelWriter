import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelThumbnail
import NovelWorkspaceUI
import NovelWritingSupport
import Testing

@MainActor
struct ThumbnailAssistantTests {
    @Test(arguments: [WritingMCPVersion.november2025, .july2026])
    func mcpReadAndWriteNeverExposeOrLoseThumbnails(version: WritingMCPVersion) async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()), initialStartupState: .ready)
        state.snapshotSyncV2Application = application
        let document = NovelDocument.newDocument(title: "合成作品"), work = WorkID(UUID())
        state.installV2Document(document, workID: work, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let image = SyncAttachment(attachmentId: UUID(), fileName: ThumbnailOwner(.work, document.id).fileName, bytes: Data("PRIVATE-THUMBNAIL".utf8))
        let orphan = SyncAttachment(attachmentId: UUID(), fileName: ThumbnailOwner(.character, UUID()).fileName, bytes: Data([2]))
        let file = SyncAttachment(attachmentId: UUID(), fileName: "合成資料.txt", bytes: Data("合成資料".utf8))
        state.snapshotSyncV2Attachments = [image, orphan, file]
        await state.reloadAttachments()
        #expect(await state.checkpointSnapshotSyncV2(document))
        let host = try #require(state.writingAssistantHost)
        let capture = try host.capture()
        let names = capture.attachments.map(\.fileName)
        #expect(names == [file.fileName])
        let listing = try await read(host, paths: [], version: version)
        #expect(!String(decoding: listing, as: UTF8.self).contains("fuminiwa-thumbnail"))
        let denied = try await read(host, paths: [["attachments", image.attachmentId.uuidString.lowercased()]], version: version)
        let response = try #require(JSONSerialization.jsonObject(with: denied) as? [String: Any])
        #expect((response["result"] as? [String: Any])?["isError"] as? Bool == true)
        let visible = try #require(capture.attachments.first)
        let edit = try WritingEdit(workId: work.rawValue, documentId: document.id,
                                   changes: [.init(path: ["attachments", visible.id.uuidString.lowercased()], before: visible.value, after: nil)])
        try await host.apply(edit, .wholeWork)
        #expect(state.snapshotSyncV2Attachments == [image, orphan])
        let reopened = try await application.openLocal(workID: work)
        #expect(reopened.attachments.count == 2)
        #expect(reopened.attachments.contains(image))
        #expect(reopened.attachments.contains(orphan))
        try await host.undo(edit.id)
        #expect(state.snapshotSyncV2Attachments.contains(image))
        #expect(state.snapshotSyncV2Attachments.contains(orphan))
        #expect(state.snapshotSyncV2Attachments.contains(file))
    }

    @Test func chatProofreadingAndFeedbackPayloadsHaveNoThumbnail() throws {
        let document = NovelDocument.newDocument(title: "合成作品")
        let image = WritingAttachment(id: UUID(), fileName: ThumbnailOwner(.work, document.id).fileName,
                                      bytes: Data("SYNTHETIC-PRIVATE-IMAGE".utf8))
        let capture = WritingCapture(workId: UUID(), document: document, episodeId: document.chapters[0].episodes[0].id, attachments: [image])
        #expect(capture.attachments.isEmpty)
        let config = try AssistantConfiguration(endpoint: "https://example.com/v1/chat/completions", model: "test", prompt: "合成指示")
        let chat = try config.chatRequest(capture: capture, grant: .readOnly, messages: [], apiKey: "unit-test-only", effectivePrompt: "合成指示", referenceScope: .current)
        let plain = try config.request(manuscript: .init(title: "合成作品", content: "合成本文"), apiKey: "unit-test-only")
        for request in [chat, plain] {
            let body = try #require(request.httpBody)
            let text = String(decoding: body, as: UTF8.self)
            #expect(!text.contains(image.fileName))
            #expect(!text.contains(image.bytes.base64EncodedString()))
            #expect(!text.contains("image_url"))
        }
    }

    private func read(_ host: WritingAssistantHost, paths: [[String]], version: WritingMCPVersion) async throws -> Data {
        let input: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                    "params": ["name": "read_work", "arguments": ["paths": paths],
                                               "_meta": ["io.modelcontextprotocol/protocolVersion": version.rawValue,
                                                         "io.modelcontextprotocol/clientCapabilities": [:]]]]
        let response = try await WritingMCPProtocol.respond(JSONSerialization.data(withJSONObject: input), host: host, version: version)
        return try #require(response)
    }
}
