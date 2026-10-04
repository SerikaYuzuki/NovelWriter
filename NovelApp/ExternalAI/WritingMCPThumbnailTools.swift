#if os(macOS)
import Foundation
import NovelWorkspaceUI
import NovelWritingSupport

extension WritingMCPProtocol {
    static var thumbnailTools: [[String: Any]] {
        let target: [String: Any] = ["type": "object", "properties": [
            "kind": ["type": "string", "enum": ["work", "character", "world-note"]], "id": [
                "type": "string",
                "format": "uuid"
            ]
        ], "required": ["kind", "id"], "additionalProperties": false]
        let context: [String: Any] = ["workId": ["type": "string"], "sessionId": ["type": "string"], "target": target]
        let scope: [String: Any] = ["type": "object", "properties": [
            "paths": ["type": "array", "items": ["type": "array", "items": ["type": "string"]]],
            "appendOnly": ["type": "boolean"]
        ], "required": ["paths", "appendOnly"], "additionalProperties": false]
        let crop: [String: Any] = ["type": "object", "properties": [
            "centerX": ["type": "number", "minimum": 0, "maximum": 1],
            "centerY": ["type": "number", "minimum": 0, "maximum": 1], "zoom": [
                "type": "number",
                "minimum": 1,
                "maximum": 8
            ]
        ], "additionalProperties": false]
        let mutation = context
            .merging(["requestId": ["type": "string", "format": "uuid"], "scope": scope]) { _, new in new }
        func tool(_ name: String, _ description: String, properties: [String: Any], required: [String],
                  readOnly: Bool) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": [
                 "type": "object",
                 "properties": properties,
                 "required": required,
                 "additionalProperties": false
             ],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": !readOnly, "openWorldHint": false]]
        }
        return [
            tool(
                "read_thumbnail",
                "現在の作品の表紙・人物・世界観サムネイルをJPEG画像として読む。workIdとsessionIdはread_workで確認。"
                    + "target.kindはwork/character/world-note、idはdocumentまたは項目のUUID。画像がなければexists:false。",
                properties: context,
                required: ["workId", "sessionId", "target"],
                readOnly: true
            ),
            tool("set_thumbnail", "指定した対象のサムネイルを設定・差し替え。imageはPNG/JPEG/HEIC/WebP静止画のbase64（8MiB・8192px・3200万画素以内）。"
                + "cropは向き適用後の左上原点、正規化中心とzoom（1〜8）、省略は中央。"
                + "scope.pathsはthumbnails/work/documentUUID、thumbnails/characters/UUID、thumbnails/worldNotes/UUID。"
                + "パスのUUIDは小文字。appendOnly:false。requestIdは再送時も同じUUID。undo_editで取り消せる。",
                properties: mutation.merging([
                    "image": ["type": "string", "contentEncoding": "base64"],
                    "crop": crop
                ]) { _, new in new },
                required: ["workId", "sessionId", "requestId", "scope", "target", "image"], readOnly: false),
            tool("remove_thumbnail", "指定範囲のサムネイルを削除。対象・scopeはset_thumbnailと同じ。requestIdは再送時も同じUUID。undo_editで元画像に戻せる。",
                 properties: mutation, required: ["workId", "sessionId", "requestId", "scope", "target"],
                 readOnly: false)
        ]
    }

    static func thumbnailTool(_ name: String, arguments: [String: Any], capture: WritingCapture,
                              host: WritingAssistantHost) async throws -> [String: Any] {
        try requireContext(arguments, capture: capture, host: host)
        if name == "read_thumbnail" {
            guard let target = arguments["target"] as? [String: Any] else { throw WritingError.invalidEdit }
            let owner = try WritingMCPThumbnailRequest.owner(target)
            guard owner.exists(in: capture.document) else { throw WritingError.changedTarget }
            if let image = try await host.readThumbnail(owner) {
                return [
                    "content": [["type": "image", "data": image.base64EncodedString(), "mimeType": "image/jpeg"]],
                    "isError": false
                ]
            }
            return try content(["exists": false, "message": "サムネイルは設定されていません。"])
        }
        let (request, grant) = try WritingMCPThumbnailRequest.make(
            arguments,
            capture: capture,
            removing: name == "remove_thumbnail"
        )
        if let state = try await host.editOutcome(request.edit) {
            return try content(["applied": state == "applied", "state": state, "replayed": true,
                                "requestId": request.edit.id.uuidString.lowercased()])
        }
        let state = try await host.applyThumbnail(request, grant)
        return try content([
            "applied": state == "applied",
            "state": state,
            "requestId": request.edit.id.uuidString.lowercased()
        ])
    }
}
#endif
