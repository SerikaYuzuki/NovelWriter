import Foundation
@testable import FUMINIWA
import ImageIO
import NovelCore
import NovelSyncV2
import NovelThumbnail
import NovelWorkspaceUI
import NovelWritingSupport
import Testing

@MainActor
struct MCPThumbnailBoundaryTests {
    @Test func readingMalformedReservedImageDoesNotMislabelItAsJPEG() async throws {
        let fixture = try await MCPThumbnailHarness.make(), owner = fixture.owner()
        fixture.state.snapshotSyncV2Attachments = try [.init(attachmentId: UUID(), fileName: owner.fileName,
                                                             bytes: MCPThumbnailHarness.source())]
        #expect(try await fixture.call("read_thumbnail", fixture.arguments(owner))["isError"] as? Bool == true)
    }

    @Test func pixelBudgetAndIncompleteImagesAreRejectedBeforeDecode() throws {
        let image = try MCPThumbnailHarness.source(.jpeg, width: 6000, height: 6000)
        let source = try #require(CGImageSourceCreateWithData(
            image as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 6000)
        #expect(image.count < WritingMCPThumbnailImage.maximumSourceBytes)
        #expect(throws: WritingError.invalidEdit) { try WritingMCPThumbnailImage.validate(image) }
        let complete = try MCPThumbnailHarness.source()
        #expect(throws: WritingError.invalidEdit) { try WritingMCPThumbnailImage.validate(Data(complete.prefix(33))) }
        let animation = try MCPThumbnailHarness.source(.png, frames: 2)
        let animatedSource = try #require(CGImageSourceCreateWithData(animation as CFData, nil))
        #expect(CGImageSourceGetCount(animatedSource) == 2)
        #expect(throws: WritingError.invalidEdit) { try WritingMCPThumbnailImage.validate(animation) }
    }

    @Test func checkpointFailureKeepsPreviousImageAndPreparedClaim() async throws {
        let control = ThumbnailSaveControl()
        var dependencies = AppDependencies(userDefaults: makeIsolatedTestUserDefaults())
        dependencies.snapshotSyncV2CheckpointOverride = { app, work, doc, reason, date, attachments, resources in
            if control.fail {
                throw CocoaError(.fileWriteUnknown)
            }
            return try await app.checkpoint(workID: work, document: doc, reason: reason,
                                            documentCreatedAt: date, attachments: attachments,
                                            resources: resources)
        }
        let fixture = try await MCPThumbnailHarness.make(dependencies: dependencies), owner = fixture.owner()
        let image = try ThumbnailEncoder.encode(MCPThumbnailHarness.source(), owner: owner)
        #expect(await fixture.state.setThumbnail(image, owner: owner, session: fixture.state.workspaceModel.documentSessionToken,
                                                 account: fixture.state.snapshotSyncV2AccountScopeToken))
        let before = fixture.state.snapshotSyncV2Attachments, id = UUID()
        var args = try fixture.arguments(owner, requestID: id, image: MCPThumbnailHarness.source())
        args["crop"] = ["zoom": 2]
        control.fail = true
        #expect(try await fixture.call("set_thumbnail", args)["isError"] as? Bool == true)
        #expect(fixture.state.snapshotSyncV2Attachments == before)
        #expect(try await fixture.application.openLocal(workID: fixture.work).attachments == before)
        control.fail = false
        let replay = try await fixture.call("set_thumbnail", args)
        #expect(try fixture.output(replay)["state"] as? String == "prepared")
        #expect(try fixture.output(replay)["applied"] as? Bool == false)
        #expect(fixture.state.snapshotSyncV2Attachments == before)
    }

    @Test(arguments: ["account", "work", "owner"])
    func staleCheckpointCompletionDoesNotInstallImage(change: String) async throws {
        let control = ThumbnailSaveControl()
        var dependencies = AppDependencies(userDefaults: makeIsolatedTestUserDefaults())
        dependencies.snapshotSyncV2CheckpointOverride = { app, work, doc, reason, date, attachments, resources in
            let result = try await app.checkpoint(workID: work, document: doc, reason: reason,
                                                  documentCreatedAt: date, attachments: attachments,
                                                  resources: resources)
            if control.pause {
                control.didPause = true
                await withCheckedContinuation { control.continuation = $0 }
            }
            return result
        }
        let fixture = try await MCPThumbnailHarness.make(dependencies: dependencies), owner = fixture.owner(.character)
        let args = try fixture.arguments(owner, image: MCPThumbnailHarness.source())
        control.pause = true
        let task = Task { try await fixture.call("set_thumbnail", args)["isError"] as? Bool == true }
        for _ in 0 ..< 100 {
            if control.didPause {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let continuation = try #require(control.continuation)
        control.pause = false
        if change == "account" {
            fixture.state.snapshotSyncV2AccountScopeGeneration &+= 1
        } else if change == "work" {
            fixture.state.installV2Document(.newDocument(title: "別の合成作品"), workID: WorkID(UUID()), createdAt: Date())
        } else {
            #expect(fixture.state.deleteCharacter(id: fixture.state.workspaceModel.document.characters[0].id))
        }
        continuation.resume()
        #expect(try await task.value)
        #expect(fixture.state.thumbnailData(owner) == nil)
    }

    @Test func thumbnailToolsWaitForCompositionAndRejectCancelledRequest() async throws {
        let fixture = try await MCPThumbnailHarness.make(), original = try #require(fixture.state.writingAssistantHost)
        var host = original, captures = 0
        host = WritingAssistantHost(contextID: original.contextID, capture: {
            captures += 1
            if captures < 3 {
                throw AssistantError.composing
            }
            return try original.capture()
        }, records: original.records, append: original.append, synchronize: original.synchronize,
        apply: original.apply, undo: original.undo, editState: original.editState,
        editOutcome: original.editOutcome,
        readThumbnail: original.readThumbnail, applyThumbnail: original.applyThumbnail)
        let args = try fixture.arguments(fixture.owner(), image: MCPThumbnailHarness.source())
        #expect(try await fixture.call("set_thumbnail", args, host: host)["isError"] as? Bool == false)
        #expect(captures == 3)
        let waiting = WritingAssistantHost(contextID: original.contextID, capture: { throw AssistantError.composing },
                                           records: original.records, append: original.append,
                                           synchronize: original.synchronize,
                                           apply: original.apply, undo: original.undo)
        let before = fixture.state.snapshotSyncV2Attachments
        let task = Task { try await fixture.call("set_thumbnail", args, host: waiting)["isError"] as? Bool == true }
        task.cancel()
        #expect(try await task.value)
        #expect(fixture.state.snapshotSyncV2Attachments == before)
    }
}

@MainActor
private final class ThumbnailSaveControl {
    var fail = false
    var pause = false
    var didPause = false
    var continuation: CheckedContinuation<Void, Never>?
}
