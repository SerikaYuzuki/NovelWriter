import CoreGraphics
import Foundation
@testable import FUMINIWA
import ImageIO
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelThumbnail
import NovelWorkspaceUI
import NovelWritingSupport
import Testing
import UniformTypeIdentifiers

@MainActor
struct MCPThumbnailHarness {
    let state: AppState
    let application: SyncV2Application
    let work: WorkID
    let configuration: TestRuntimeConfiguration

    static func make(dependencies: AppDependencies? = nil) async throws -> Self {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let state = AppState(
            dependencies: dependencies ?? AppDependencies(userDefaults: makeIsolatedTestUserDefaults()),
            initialStartupState: .ready
        )
        state.snapshotSyncV2Application = application
        var document = NovelDocument.newDocument(title: "合成作品")
        document.characters = [Character(name: "合成人物")]
        document.worldNotes = [WorldNote(title: "合成世界", content: "合成設定")]
        let work = WorkID(UUID())
        state.installV2Document(document, workID: work, createdAt: Date())
        #expect(await state.checkpointSnapshotSyncV2(document))
        return Self(state: state, application: application, work: work, configuration: configuration)
    }

    func owner(_ kind: ThumbnailOwner.Kind = .work) -> ThumbnailOwner {
        switch kind {
        case .work: ThumbnailOwner(kind, state.workspaceModel.document.id)
        case .character: ThumbnailOwner(kind, state.workspaceModel.document.characters[0].id.rawValue)
        case .worldNote: ThumbnailOwner(kind, state.workspaceModel.document.worldNotes[0].id.rawValue)
        }
    }

    func arguments(_ owner: ThumbnailOwner, requestID: UUID = UUID(), image: Data? = nil) throws -> [String: Any] {
        let host = try #require(state.writingAssistantHost)
        var args: [String: Any] = [
            "workId": work.description,
            "sessionId": host.contextID,
            "requestId": requestID.uuidString,
            "target": ["kind": owner.kind.rawValue, "id": owner.id.uuidString],
            "scope": ["paths": [WritingMCPThumbnailRequest.path(owner)], "appendOnly": false]
        ]
        args["image"] = image?.base64EncodedString()
        return args
    }

    func call(_ name: String, _ args: [String: Any], host: WritingAssistantHost? = nil,
              version: WritingMCPVersion = .july2026) async throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": name, "arguments": args,
            "_meta": [
                "io.modelcontextprotocol/protocolVersion": version.rawValue,
                "io.modelcontextprotocol/clientCapabilities": [:]
            ]
        ]]
        let body = try #require(await WritingMCPProtocol.respond(
            JSONSerialization.data(withJSONObject: request),
            host: host ?? state.writingAssistantHost,
            version: version
        ))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(object["result"] as? [String: Any])
    }

    func output(_ result: [String: Any]) throws -> [String: Any] {
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func undo(_ id: UUID) async throws -> [String: Any] {
        try await call("undo_edit", arguments(owner(), requestID: id))
    }

    static func source(_ type: UTType = .png, width: Int = 160, height: Int = 100, frames: Int = 1) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
        for _ in 0 ..< frames {
            CGImageDestinationAddImage(destination, image, nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
